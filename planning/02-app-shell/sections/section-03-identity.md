# Section 03: Identity (EikonCore/Identity)

## Purpose and background

Eikon is an iPhone/iPad app that runs Windows, Linux x86 and some native-engine games inside the app process. Split 02 (the app shell) gives every game an identity. The identity has two parts:

- A **game id**: a random UUID, minted once. Settings, saves and later per-game data are keyed on it. It never encodes anything about the game.
- A **content fingerprint** that lets the app find the same game again after:
  - a rename of its folder
  - a move to another game drive
  - a patch copied over its files
  - the same game turning up on a second device

This follows the common launcher pattern (Playnite, Heroic, Bottles): an opaque id owned by Eikon. The id is found again through a content fingerprint, the way emulators use disc ids and ROM hashes, and the way PC engines use their declared save ids.

- Names are never keys.
- Renames, moves between drives, patches and a second device all match silently.
- The user is asked only when the match is genuinely ambiguous, and never in a blocking way.
- A wrong match produces a **duplicate entry**, never two games sharing settings or saves.

This section builds the pure, platform-neutral identity logic in the `EikonCore` SwiftPM package (`Packages/EikonCore`, iOS 15 + macOS 13, Swift 6 language mode, no UIKit). It covers:

- the types `GameID`, `Fingerprint`, `Keyed`, plus the library secret
- `NameNormalizer`
- `KeyFile`, which picks the key file per engine
- `EngineDeclaredID`, with its generic-value blocklist
- `FingerprintBuilder`, which turns signals into HMAC-keyed values
- `IdentityMatcher`, which applies the matching rules, including in-place patches keeping the game id
- merge and split, with `merged/` link resolution
- `FileHasher`, a streaming full SHA-256 used by the exact signal and by diagnostics

> **Changed in code review (owner decisions).** Files alone identify a game only when the folders are **100% identical, excluding saves**. So the exact signal is a full content hash of the whole tree, not a listing plus key-file sample. There is no file-name similarity rule at all: no attach and no suggestion. The name set (`names`, `Keyed8`, Jaccard, `nameSimilarityThreshold`) was removed.

Things outside this section:

- Persisting fingerprints in settings (`game/<id>/fp/<scheme>/<exact>`) and writing the `merged/<A>` global key happen in section 05 (settings store) and section 09 (library). This section only provides the pure in-memory logic those sections apply.
- The collection scanner (section 04) uses `FingerprintBuilder` with a fixed scanner secret and reports identity statistics.

### Dependencies

- **Requires section 01 (core package)** for the `EikonCore` package, test target and `make test-core`. `EikonCore` already uses CryptoKit, which is available on iOS 15 and macOS 13.
- **Requires section 02 (detection)** for:
  - `Engine`, `DetectionResult` (including its `keyFile: String?` field and `gameRoot`), `ExecutableInfo`, `GamePlatform`
  - `FolderListing` (case-insensitive, NFC-normalized lookups)
  - `FolderReader` (budgeted, read-only reads)
  - `PEVersionResource` (reads VS_VERSIONINFO strings)
  - the GameMaker GEN8 chunk walk
  - `GameDetector.detect(folder:)`
  - the test fixture synthesizer `Tests/EikonCoreTests/Fixtures.swift`
- **Blocks:** section 04 (collection scanner) and section 09 (library and drives).

### Project constraints that apply here

- **No program titles anywhere**: not in the repo, logs, tests, reports or output. Folder names, engine ids and display names are titles in practice.
  - Plain signals are never stored or synced. Only HMAC-keyed values are.
  - Test fixtures use generic, original content (`Game.exe`, `Sample_Data`, `data.xp3`, and made-up strings like `fixture-company` / `fixture-product`). Nothing comes from the real game collection.
- **Swift 6 language mode**, complete concurrency checking. All public types are `Sendable`.
- **01's style.**
  - Small single-concept files.
  - Pure logic goes in caseless enums.
  - `Sendable` protocol seams where I/O is involved.
  - Enums decode unknown raw values to a fallback rather than failing.
- **Tests are few and behavioral.** They must not assert constants, exact strings, file contents or internal structure.
  - Where a test depends on a threshold or cap, reference the public constant (for example `Fingerprint.maxPerGame`, `FileHasher.chunkSize`) rather than typing the number into the test.
- **Read-only** access to game folders. Never write, never follow symlinks out of the folder. Reads go through section 02's `FolderReader`.

## Files

Create under `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonCore/Sources/EikonCore/Identity/`:

| File | Contents |
|---|---|
| `GameIdentity.swift` | `GameID`, `Fingerprint`, `Keyed`, `LibrarySecret`, `IdentityError` |
| `NameNormalizer.swift` | NFC + trim + case-fold of names (listings, folder names) |
| `KeyFile.swift` | key file selection per engine |
| `EngineDeclaredID.swift` | engine-declared id readers + generic blocklist table |
| `FingerprintBuilder.swift` | signals → keyed `Fingerprint` |
| `IdentityMatcher.swift` | `KnownGame`, `LocationKey`, `MatchRule`, `MatchResult`; matching rules (pure), fingerprint cap, merge-link resolution |
| `IdentityLedger.swift` | merge and split over an in-memory ledger (split out of `IdentityMatcher.swift` to keep files single-concept) |
| `FileHasher.swift` | streaming full-file SHA-256 (exact signal and diagnostics) |

Create or extend tests:

- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonCore/Tests/EikonCoreTests/IdentityTests.swift` (new).
- `/Volumes/WD_SN770_1T/dev/GitHub/eikon/Packages/EikonCore/Tests/EikonCoreTests/Fixtures.swift` (extend). Add builders for:
  - a Unity `<stem>_Data/app.info`
  - a Ren'Py `game/options.rpy` containing a `config.save_directory` line
  - GEN8 `Name` / `DisplayName` strings in a GameMaker `data.win`
  - `CompanyName` / `ProductName` in a PE version resource

  Some of these builders may already exist from section 02. Extend them rather than duplicate them.

Modify, where section 02 left a placeholder:

- `Packages/EikonCore/Sources/EikonCore/Detection/GameDetector.swift` fills `DetectionResult.keyFile` using `KeyFile`, and `GameDetector.version` is bumped to 2 so cached results without a key file are recomputed.
- `FolderListing.normalize` was removed; `FolderListing` and `DetectionTests` call `NameNormalizer.normalize`, which now also trims whitespace.
- `GameMakerDetector.swift` shares its chunk walk (`dataFile`, `chunk`) and adds `declaredNames` (GEN8 Name at +40, DisplayName at +100, STRG pointers to the bytes after a 32-bit length).
- `FolderReader.swift` gains the `gen8Strings` read purpose (4 KiB).

## Tests first

All tests use Swift Testing (`import Testing`, free `@Test func` with behavior names, `#expect` / `#require`, `@Test(arguments:)` for tables). Put fakes at the top of the file and do all file work in temp directories. Run with `make test-core` (`swift test --package-path Packages/EikonCore`).

### Signals and fingerprints (§5.2)

- Test: renaming the game folder (not its contents) leaves the fingerprint unchanged.
- Test: changing an existing file's size, or one byte deep in the tree at the same size, changes the exact signal but leaves the engine id unchanged.
- Test: writing save files (`game/saves/…`, `savedata/…`) leaves the fingerprint unchanged.
- Test: OS metadata (`.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`) leaves the fingerprint unchanged.
- Test: the engine-declared id is read for:
  - Ren'Py (`options.rpy` `config.save_directory`)
  - Unity (`app.info`)
  - GameMaker (GEN8 name)
  - exe version info

  Parameterize over fixtures and check that `engineID` is non-nil. Don't compare against the literal plain text.
- Test: a generic value such as `DefaultCompany` / `My project` or `TVP(KIRIKIRI)` yields no engine id.
- Test: the stored fingerprint contains none of the plain names or engine-id text. Encode the `Fingerprint` to JSON and check that none of the fixture's folder names, file names or declared-id strings appear as substrings.
- Test: the same folder under two different secrets gives different values, and under the same secret equal values.
- Test: `LibrarySecret.loadOrCreate` creates once, then reads back the same secret.
- Test: the Ren'Py key file is never the launcher exe, and the Unity key file is never the player exe.

### Matcher (§5.4)

Write these table-driven over in-memory state, one row per rule:

- Test: **in-place patch.** A known location whose contents changed entirely (new sizes, new files, new engine id) keeps its game id, and the new fingerprint is added.
- Test: an exact match of a folder under a new name or on another drive attaches to the existing game.
- Test: an engine-id match attaches silently when the game has no live location on this device. This covers a patched and moved copy, and a newer version on another device.
- Test: an engine-id match while the game is live elsewhere creates a new game with a suggestion, never a silent merge.
- Test: with no engine id and no exact match, the result is a new game with no suggestions (file names never match).
- Test: two candidates create a new game plus a suggestion listing both.
- Test: no match creates a new random id.
- Test: a game with `deletedAt` is never a candidate.
- Test: fingerprints beyond the cap keep the most recent ones, and re-adding an equal one moves it to newest.
- Test: two unmatched folders get distinct random ids.

### Merge and split (§5.5)

- Test: after a merge:
  - A's id resolves to B
  - A's locations belong to B
  - B keeps its own settings where both had a value
- Test: merge links in a chain resolve to the end, and a cycle resolves to the same id from either side.
- Test: a split gives the location a new id whose settings equal the old game's at split time. Later edits to either don't affect the other.

### Diagnostics hasher (§5.6)

- Test: `FileHasher` equals an independent SHA-256 (CryptoKit `SHA256.hash(data:)` over the whole file, in the test) and reports non-decreasing progress.
- Test: `FileHasher` stops early on cancel.

Final count: `IdentityTests.swift` holds 18 test functions (several parameterized); the package runs 49.

## Implementation

### 1. Types (`GameIdentity.swift`)

```swift
public struct GameID: Hashable, Codable, Sendable { public let uuid: UUID }   // random, minted once

public struct Fingerprint: Codable, Sendable, Equatable {
    public var scheme: Int                   // bump to change how fingerprints are computed
    public var engineID: Keyed?              // engine-declared identity, keyed
    public var exact: Keyed                  // full content hash of the tree (saves excluded), keyed
}
public struct Keyed:  Hashable, Codable, Sendable { public let hex: String }   // HMAC-SHA256, 64 hex
```

- `GameID`:
  - Provide `static func random() -> GameID`.
  - Provide a `reportID` computed property: the first 8 characters of the lowercase UUID string. It is used later in crash issues (section 07). The id is random, so the report id reveals nothing.
  - `GameID` is `Comparable` by lowercase `uuidString`; merge-cycle breaking uses it. It codes as the bare UUID string.
- `Fingerprint`:
  - Expose `static let currentScheme: Int` (start at 1).
  - Expose `static let maxPerGame: Int` (8). This is the cap on fingerprints kept per game: one per distinct build seen, most recent kept.
- `LibrarySecret`: 32 random bytes held as a `SymmetricKey`-compatible value.
  - `static func loadOrCreate(at url: URL) throws -> LibrarySecret`. It creates the file once and later reads it back. Creation writes a temp file and `link()`s it into place, so it never replaces an existing secret; a creator that loses the race reads the winner's.
  - Section 09 calls this with `Application Support/Eikon/library-secret`.
  - Also provide `init(bytes: Data)` so the scanner (section 04) can pass its fixed, documented scanner secret, and so tests can pass arbitrary secrets.
  - Never log or export the secret.
  - A second device must use the same secret for fingerprints to compare equal. Carrying the secret between devices is split 12's job. Until then each device has its own secret.

### 2. `NameNormalizer`

A caseless enum with `static func normalize(_ name: String) -> String`. It:

1. applies Unicode NFC (`precomposedStringWithCanonicalMapping`)
2. trims whitespace
3. case-folds (`folding(options: [.caseInsensitive], locale: nil)`), then NFC again so a normalized name normalizes to itself

It is used for:

- directory listing lookups (section 02's `FolderListing` should call it)
- the exact-signal paths below
- the matcher's "same folder name" comparison
- the import name clash check (section 09)

### 3. `KeyFile`

The key file is the game's main data file, recorded in `DetectionResult.keyFile` for detection output and the scanner. (It was planned as the exact signal's sampled file; with full content hashing the fingerprint no longer uses it.) It is chosen per engine as the **first entry in this table that exists**, looked up through `FolderListing`:

| Engine | Key file (first that exists) |
|---|---|
| Kirikiri | `data.xp3`, then the largest root `.xp3`, then the main exe |
| GameMaker | `data.win` / `game.unx` |
| Unity | `GameAssembly.dll`/`.so`, `<stem>_Data/Managed/Assembly-CSharp.dll`, `<stem>_Data/globalgamemanagers` |
| Ren'Py | the largest `game/*.rpa`, then the largest `game/*.rpyc` |
| BGI / unknown | the main exe |

- Signature, for example: `static func locate(engine: Engine, executables: [GamePlatform: ExecutableInfo], root: URL) throws -> String?`. It returns a path relative to the game root.
- For Unity, `<stem>` is the main executable's stem. The Unity player exe and `UnityPlayer.dll` are never key files.
- For Ren'Py, the launcher exe is never the key file.
- For "main exe", use the Windows executable if present, otherwise the Linux one.
- For Unity, if no `<stem>_Data` exists the first `*_Data` folder is used (`KeyFile.unityDataDirectory`, shared with `EngineDeclaredID`).
- Wire it into `GameDetector` so `DetectionResult.keyFile` is populated for every detected game.

### 4. `EngineDeclaredID`

This reads the identity the game's engine uses for its own saves. It is the signal most likely to survive a patch.

| Source | What to read |
|---|---|
| Ren'Py | `config.save_directory` from `game/options.rpy` when shipped. A small-text read within `FolderReader`'s ≤64 KiB budget; parse the quoted string assigned to `config.save_directory`. A bounded best-effort scan of `.rpyc` data is optional. If the value isn't found, the signal is absent (nil). |
| Unity | company and product from `<stem>_Data/app.info`, which is two lines of plain text |
| GameMaker | the GEN8 `Name` and `DisplayName` strings, reusing section 02's chunk walk and string reading |
| Windows executables (any engine, including Kirikiri, BGI and unknown) | `CompanyName` + `ProductName` from the main exe's version resource, via section 02's `PEVersionResource` |

Details:

- **Generic-value blocklist.** Windows version values are dropped when they are an engine's generic values, for example `TVP(KIRIKIRI)`, `Unity`, `DefaultCompany` and `My project`.
  - The blocklist is one static table (`EngineDeclaredID.genericValues`), compared through `NameNormalizer`. It holds Kirikiri, Unity, Ren'Py and GameMaker defaults.
  - Apply it to Unity `app.info` values too, since `DefaultCompany` / `My project` are Unity defaults.
  - A declared id made only of blocklisted parts is absent.
  - `EngineDeclaredID.read(detection:folder:)` returns `Result`: `.found(String)`, `.generic` or `.absent`, so the scanner (section 04) can count "declared ids that hit the generic blocklist". Unity `app.info` keeps empty lines, so an empty company line doesn't shift the product.
  - Scanner data extends this table later.
- **Engine prefix.** The plain value is prefixed with the engine raw value and a colon (`"renpy:" + value`) before keying.
- **Precedence.** The engine-specific source (Ren'Py, Unity, GameMaker) wins. Otherwise use the exe version info.
- The plain value exists only in memory inside `FingerprintBuilder`, and is never returned from public API in stored form.

### 5. `FingerprintBuilder`

`static func build(detection: DetectionResult, folder: URL, secret: LibrarySecret, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> Fingerprint`, with `scheme = Fingerprint.currentScheme`. Every signal is computed from the **game root** (`folder` + `detection.gameRoot`), never from the game folder's own name, so renaming the folder changes nothing.

- **Engine id.** HMAC-SHA256(secret, `"<engine>:<value>"`) as `Keyed`, or nil.
- **Exact signal.** HMAC-SHA256(secret, canonical bytes) over the **whole tree** of the game root, depth-first in normalized-name order. Per entry: a kind byte and the length-prefixed normalized relative path; files add their size and full SHA-256 (streamed through `FileHasher`).
  - Two folders share it only when they are 100% identical apart from what is excluded.
  - Excluded at any depth: save folders (`FingerprintBuilder.saveFolders`: save, saves, savedata, savegame, savegames), dot-files (`.DS_Store`, `._*` AppleDouble) and OS metadata (`Thumbs.db`, `desktop.ini`).
  - Symlinks are recorded by name and never followed.
  - Any unreadable file throws `IdentityError.fileUnreadable`; nothing is silently dropped.
- **Cost.** A fingerprint reads every byte of the game. Callers (import and library scans, section 09) run it in the background with `progress` (non-decreasing, 0…1) and `isCancelled` (checked between 1 MiB chunks, throws `CancellationError`). Game files are opened read-only with `O_NOFOLLOW`; the declared-id reads still go through `FolderReader`.
- **Privacy.** Plain names and engine-id text never appear in the resulting `Fingerprint` or its JSON.
- **Also public (added in the split re-review):**
  - `FingerprintBuilder.engineID(detection:folder:secret:)`: the keyed declared id alone, a few small reads, for the quick identity pass.
  - `FingerprintBuilder.contentStamp(detection:folder:)`: a cheap digest of every entry's path plus each file's size and mtime, with the same exclusions (directory mtimes left out, so a save landing in a folder doesn't count). Section 09 uses it for finished-copy detection, change detection, and to discard a hash that went stale while it ran. Local only.

### 6. `IdentityMatcher` (pure)

A caseless enum with pure functions over in-memory input. Suggested shapes (adjust names freely):

```swift
public struct KnownGame: Sendable {
    public var id: GameID
    public var fingerprints: [Fingerprint]     // oldest → newest, ≤ Fingerprint.maxPerGame
    public var hasLiveLocationHere: Bool       // a present (not missing) location on this device
    public var isDeleted: Bool                 // deletedAt set → never a candidate
}
public struct LocationKey: Hashable, Sendable { public var driveID: UUID; public var folderName: String } // normalized
public enum MatchRule { case exact, engineID }
public enum MatchResult: Sendable, Equatable {
    case keep(GameID)                                   // rule 1
    case attach(GameID, MatchRule)                      // rules 2–3, add fingerprint
    case newGame(GameID, suggestions: [GameID])         // rule 4 (suggestions may be empty)
}
public static func match(fingerprint: Fingerprint, at location: LocationKey,
                         knownLocations: [LocationKey: GameID], games: [KnownGame],
                         mint: () -> GameID = GameID.random) -> MatchResult
```

- `LocationKey` normalizes `folderName` in its initializer (`public private(set)`).
- `match` expects ids already resolved through merge links. If `knownLocations` points at a deleted game, rule 1 is skipped.
- Compare fingerprints only when their `scheme` values are equal.
- Candidates are games that are not deleted. Deleted games (with `deletedAt` set) are never candidates, so a game re-imported after its data was deleted starts fresh.

**Rules, applied in order:**

1. **Known location.** The same drive and same normalized folder name already have a game id: keep that id, **whatever changed inside**. This is how an **in-place update** is recognized: the user copies a patch over the game's files, or uses Import → *Replace existing copy*. The caller adds the new fingerprint to the game.
2. **Exact match.** `exact` equals a fingerprint of exactly one game: attach to it. This covers:
   - a rename
   - a move to another drive
   - a second copy on another drive (the game then has two locations)
   - the same game on another device
3. **Engine-id match.** The new `engineID` is non-nil and equals an `engineID` of one of exactly one game's fingerprints:
   - If that game has **no live location on this device**, attach silently and add the fingerprint. This covers a patched copy that was moved, renamed or re-imported, and a newer version from another device.
   - If that game **does** have a live location here, this is a different version sitting beside the known one. Create a **new** game with a suggestion naming that game. It is never a silent merge.
4. **Otherwise** mint a new game id.
   - If more than one candidate matched under rule 2 or 3, attach to none: create a new game with a suggestion listing all candidates (sorted by id).
   - With no candidates, the suggestion list is empty.
   - **File names never match and never suggest.** The planned name-similarity rule was dropped at the owner's decision: engine-standard layouts make unrelated games look alike, and files alone may identify a game only when they are 100% identical (rule 2).

**Quick pass.** `IdentityMatcher.quickMatch(engineID:scheme:at:knownLocations:games:mint:)` applies rules 1 and 3 only, before the full hash exists, so a location gets a game id at once (a new one is provisional). Section 09 runs `match` when the full hash finishes, and merges a provisional game with no user data into an exact-matched game silently, or else posts a suggestion.

Evaluate each rule fully before falling to the next. For example, several exact matches go straight to rule 4's multi-candidate case, rather than falling through to rule 3.

**Fingerprint cap.** A helper such as `static func adding(_ fp: Fingerprint, to list: [Fingerprint]) -> [Fingerprint]`:

- If an equal `exact` is already present, move it to newest instead of duplicating it.
- Otherwise append.
- Keep only the most recent `Fingerprint.maxPerGame`.

Suggestions are data only. Section 09 stores them on the location (`suggestion`, `dismissedSuggestions`), and section 13 shows the non-blocking card.

### 7. Merge and split

Everything here is pure. Section 09 applies the results to the settings store and the library index, and runs `GameDataMerge` hooks, which are none in 02.

- **Link resolution.** `static func resolve(_ id: GameID, links: [GameID: GameID]) -> GameID`. `links` maps a merged game A to the game B it merged into; section 09 stores these as the global setting `merged/<A>` = B so other devices follow.
  - Follow links for at most 4 hops.
  - If an id repeats (a cycle), return the lowest id among the cycle's members by the deterministic ordering, so either side of a cycle resolves to the same id.
  - If the hop limit is reached without an end, return the id reached.
- **In-memory ledger for tests and for section 09.** For example an `IdentityLedger<Setting: Sendable & Equatable>` holding:
  - `fingerprints: [GameID: [Fingerprint]]`
  - `locations: [UUID: GameID]` (location id → game id)
  - `settings: [GameID: [String: Setting]]`
  - `links: [GameID: GameID]`
- **`merge(_ a: GameID, into b: GameID)`** (both ids are first resolved through existing links):
  1. Set `links[a] = b`.
  2. Copy A's settings into B only for keys B has no value for. B's own values win.
  3. Move A's fingerprints to B (de-duplicated, cap applied, B's own builds kept newest) and clear A's.
  4. Point A's locations at B.
- **`split(location:) -> GameID`:**
  1. Mint a new id.
  2. Copy the old game's settings into it as a **fork** (an independent copy, as Lutris does when it de-duplicates). Later edits to either don't affect the other.
  3. Move that location's current fingerprint to the new game and remove it from the old game.
  4. Point the location at the new id.

  The caller supplies the location's fingerprint.

Both operations are rare and explicit ("Same game as…" and "This is a different game" in the game menu, section 13). They are never modal.

### 8. `FileHasher`

Full SHA-256 streaming. `FingerprintBuilder` uses its internal `digest(of:isCancelled:opened:read:)` for the exact signal. The public `sha256(of:progress:isCancelled:)` is used by:

- the scanner's `--hash` (section 04)
- the "Verify files" action in game detail's developer area (section 13)

Requirements:

- Stream the file in 1 MiB chunks using CryptoKit's incremental `SHA256`. Open read-only.
- Report progress (bytes done / total) through a callback with non-decreasing values.
- Support cancellation, checked between chunks. Throw `CancellationError` or return a cancelled result, and stop reading early.
- Signature, for example: `static func sha256(of url: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws -> String` (lowercase hex). An `async` variant that honours `Task.isCancelled` is also fine.

## Done when

- `make test-core` passes with the tests above.
- `DetectionResult.keyFile` is populated by detection.
- No plain name or engine-id text can reach a stored `Fingerprint`.
- Files alone match only when 100% identical apart from saves and OS metadata.
- The public API above is available to sections 04 and 09: `FingerprintBuilder.build`, `IdentityMatcher.match`, `IdentityMatcher.adding`, `IdentityMatcher.resolve`, `IdentityLedger.merge`/`split`, `LibrarySecret`, `FileHasher`, `NameNormalizer`, `KeyFile`, and `EngineDeclaredID` with its generic/absent distinction.
