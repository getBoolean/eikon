# Section 05: Settings store (EikonCore/Settings)

## Purpose and scope

This section builds Eikon's per-game and global settings layer in the platform-neutral `EikonCore` package. Settings are stored as a **per-field last-writer-wins (LWW) map** ordered by a **hybrid logical clock (HLC)**. There is **one file per device (replica)**. The format is built so that split 12 (WebDAV sync) can later drop other devices' replica files into the same folder and merge them, with no locking and no migration.

What this section delivers, all in `Packages/EikonCore/Sources/EikonCore/Settings/`:

- `ReplicaID.swift`: the replica identifier, loaded from or created in `replica-id`.
- `HybridClock.swift`: `HybridTimestamp` (totally ordered) and `HybridClock`.
- `JSONValue.swift`: an untyped JSON value.
- `LWWMap.swift`: `LWWEntry` and `LWWMap`, with merge, tombstones, preservation of unknown keys, and `deletedAt` shadowing for effective reads.
- `SettingKey.swift`: typed keys, key builders, the keys split 02 uses, and documentation of the reserved namespaces.
- `SettingsStore.swift`: file-backed, lock-guarded and `@unchecked Sendable`. It keeps one file per replica, forks to a new replica when its own file is from a future format, and persists off the main thread with a debounce.
- `ReplicaFile.swift` (added): the tolerant `settings/<replica>.json` document.

> **Changed in code review.** Fingerprints are keyed by value (`fp/<scheme>/<digest>`) rather than numbered slots, so two devices adding different fingerprints never overwrite each other. Section 03 had landed by then, so `fingerprintCap` is `Fingerprint.maxPerGame`.

Tests go in `Packages/EikonCore/Tests/EikonCoreTests/SettingsTests.swift`.

**Out of scope:** `SettingsController`, the EikonKit `@MainActor ObservableObject` wrapper over the store, is built in section 09 (library and drives). So are the merge and split *flows* (identity sections). This section only provides the store primitives they call.

## Dependencies

- **Section 01 (core package)** must be done first. It provides:
  - the `Packages/EikonCore` package: iOS 15 + macOS 13, Swift 6 language mode, `make test-core` running `swift test --package-path Packages/EikonCore`
  - the empty `EikonCoreTests` target
  - the shared persisted-file rules type `Persisted` in `EikonCore/Library/Persisted.swift`: a `format` header, atomic writes, and the rule that a newer-format file is read-only. Use `Persisted` for every file this section writes. Do not re-implement atomic writing.
- This section can run in parallel with section 02 (detection).
- `GameID` (a struct wrapping a random `UUID`) and `Fingerprint` are defined by section 03. (It was planned to land after this one, but it landed first.) So this section's game-scoped APIs take the game's `UUID` (callers pass `gameID.uuid`), and the fingerprint APIs are generic over any `Codable & Sendable` value. Section 03 or 09 may add thin convenience overloads taking `GameID`/`Fingerprint`, but none are needed here.
- The `RouteID` enum comes later (section 06). The `route.override` key therefore stores the route's **string raw value**, following the rule that enum values are stored as their raw strings. Consumers convert it, and an unknown raw value means "no override".

### Blocks

- Section 09 (library & drives): identity matching reads known games' fingerprints, and merge, split and remove write settings.
- Section 13 (library UI): display names and the route override.
- Section 14's developer section shows the replica id and the settings-fork warning. It reads what the store exposes here.

## Background and constraints

- **Why LWW + HLC.** Split 12 merges per-device files over WebDAV with no locking. Per-field LWW registers merge without conflicts. Merge must be **commutative, associative and idempotent**, so any sync order converges.
- **Unknown fields are preserved.** A newer app version on another device may write keys this build has no `SettingKey` for. Those keys must survive load and save unchanged.
- **Reset is a tombstone**, not a deletion, so a reset propagates and beats older sets.
- **A per-game `deletedAt` marker** shadows every older key under that game's prefix. This includes keys this device never saw, which is how "delete settings and saves on all devices" works.
- **Privacy.** Display names are effectively game titles. They may live in settings, which only ever sync to the user's own server and never become paths. Never log setting values or keys that contain names. Fingerprints are stored only as keyed HMAC values, and that is section 03's concern.
- **Project style**, from split 01:
  - small single-concept files
  - pure logic in caseless enums or value types
  - `Sendable` everywhere
  - no `default:` in switches over enums this code owns
- **iOS 15 minimum.** There are no Swift `Atomic`/`Mutex` types and no `OSAllocatedUnfairLock`. Use `NSLock` (or a `pthread_mutex` wrapper) for the store's lock, and a private serial `DispatchQueue` for persistence.
- **Swift 6 complete concurrency checking.** The store is `final class … : @unchecked Sendable`, with every mutable state access under the lock.
- **Owner's test rule.** Tests are few and behavioral. They do not assert constants, file contents, exact strings or internal structure.

### Storage location

- Everything lives under `Library/Application Support/Eikon/`, resolved at runtime through `FileManager.url(for:in:)`. Never store an absolute container path.
- The store receives its **base directory as an injected URL**, so tests use a temp directory. Inside it:
  - `replica-id`: this device's replica UUID, created once.
  - `settings/<replica>.json`: one file per replica.
- The Dopamine and `.ipa` installs have separate containers and are therefore separate replicas.

## Tests first

File: `Packages/EikonCore/Tests/EikonCoreTests/SettingsTests.swift`.
- Use Swift Testing: `import Testing`, free `@Test func` with behavior names, and `#expect`/`#require`.
- Put fakes at the top of the file: an injectable clock closure, and a temp directory per test.
- Tests drive time through an injected `now` and never sleep for the debounce. They call `flush()` instead.

1. **Merge laws (property-style).**
   - Setup: seeded random operation sequences (set, reset, and `deletedAt` writes over a small key space, with random wall-clock values, including backwards jumps) across three simulated replicas, each with its own `ReplicaID` and `HybridClock`.
   - Expect: merging the three maps in any order and any grouping gives the same state (commutative, associative), and merging a map into a state a second time changes nothing (idempotent).
   - Use a fixed seed, so the test is deterministic.
2. **Reset vs set.**
   - A reset with a newer timestamp than a set wins: the key reads as unset.
   - A set newer than a reset wins: the key reads as the set value.
3. **Unknown keys round-trip.** A replica file containing keys the store has no `SettingKey` for still contains them, with the same values and timestamps, after the store loads it, performs an unrelated write, and flushes. Compare decoded entries, not bytes.
4. **Clock never goes backwards.** With the injected wall clock moved backwards between two writes to the same key, the second write still wins.
5. **Observing a future timestamp.** After merging a remote entry whose timestamp is far in the future, the next local write orders after it, so the local write wins.
6. **Another replica's future-format file.**
   - Setup: another replica's file in `settings/` has a `format` newer than the app knows.
   - Expect: its readable entries are merged into the store's view, and the file is never rewritten. It stays byte-identical after writes and flushes.
7. **Own file in a future format (fork).**
   - Setup: this replica's own file has a future `format`.
   - Expect:
     - the store writes to a **new** replica file under a new replica id
     - the old file stays byte-identical
     - the store reports that it forked
8. **`deletedAt` shadowing.**
   - `deletedAt` hides older keys under that game, including a key that only another replica's file wrote.
   - A key written after `deletedAt` is visible.
   - Other games are unaffected.
9. **Decode failure reads as unset.** A stored value that fails to decode as the key's `Value` type (for example a string stored where the key expects an integer) reads as `nil`. It does not throw or crash.
10. **Persistence round trip.** Writes are persisted after `flush()`, and a new store instance over the same directory reads them back, with the same replica id.
11. **Fingerprint cap.** (Implemented with values keyed by digest; see below.) Adding more fingerprints to a game than the cap keeps only the most recent ones, and `fingerprints(game:)` returns them. Assert "the most recently added ones survive and the oldest are gone". Do not assert the cap number itself: derive it from the store's public constant.

The plan's summary for this area lists the same behaviors: merge laws via a seeded loop, a newer reset beats an older set, unknown keys round-trip, the clock never goes backwards, future-format files are never rewritten and the own future-format file forks, and `deletedAt` hides older keys but not newer ones.

## Implementation

### `ReplicaID.swift`

- `public struct ReplicaID: Hashable, Comparable, Codable, Sendable` wrapping a `UUID`.
  - `Comparable` is needed for the deterministic tiebreak in `HybridTimestamp` ordering. Compare by the UUID's canonical string or its bytes, as long as it is consistent.
  - It encodes as the UUID string.
- A loader, for example `static func loadOrCreate(in directory: URL) throws -> ReplicaID`:
  - It reads `replica-id`.
  - If the file is missing or unreadable, it creates a random UUID and writes it atomically.
- The store also needs a way to **replace** the stored id when it forks (see below). Otherwise every launch would fork again.

### `HybridClock.swift`

```swift
public struct HybridTimestamp: Hashable, Comparable, Codable, Sendable {
    public var wallMillis: Int64
    public var counter: UInt32
    public var replica: ReplicaID
}
```

- The ordering is total and lexicographic: `wallMillis`, then `counter`, then `replica`.
- `HybridClock` is a value type holding the last issued timestamp and the owning `ReplicaID`.
  - `mutating func tick(now: Date) -> HybridTimestamp` never goes backwards:
    - wall = max(now in millis, last.wallMillis)
    - if wall equals `last.wallMillis`, then counter = last.counter + 1; otherwise counter = 0
  - `mutating func observe(_ remote: HybridTimestamp)` advances the clock so the next `tick` orders after `remote`, even when `remote` is far in the future.
  - Remote times past `HybridClock.maxWallMillis` (end of year 9999) are ignored, and non-finite or huge wall clocks are clamped, so a corrupt file can't overflow the clock.
- The replica file persists the clock's last timestamp, so after a restart it continues past everything it issued.

### `JSONValue.swift`

- `public enum JSONValue: Codable, Sendable, Equatable` with cases `null`, `bool(Bool)`, `int(Int64)`, `uint(UInt64)`, `number(Double)`, `string(String)`, `array([JSONValue])` and `object([String: JSONValue])`. Integers decode into the exact cases first, so unknown keys holding large integers round-trip unchanged.
- It uses a custom single-value `Codable`, so any JSON round-trips.
- Typed accessors convert between `Value: Codable` and `JSONValue` through `JSONEncoder`/`JSONDecoder`: encode the value, then decode the result as `JSONValue`, and the reverse for reads.
  - Integers are exact across the Int64 / UInt64 range.

### `LWWMap.swift`

```swift
public struct LWWEntry: Codable, Sendable, Equatable {
    public var value: JSONValue        // .null for tombstones
    public var time: HybridTimestamp
    public var isTombstone: Bool
}

public struct LWWMap: Codable, Sendable, Equatable {
    public private(set) var entries: [String: LWWEntry]
    public mutating func set(_ key: String, _ value: JSONValue, at time: HybridTimestamp)
    public mutating func reset(_ key: String, at time: HybridTimestamp)   // writes a tombstone
    public mutating func merge(_ other: LWWMap)
    /// Effective read: nil if absent, tombstoned, or shadowed by the game's deletedAt.
    public func effectiveValue(_ key: String) -> JSONValue?
}
```

- **`merge`:** for each key, keep the entry with the greater `time`. Equal timestamps imply the same write, because the replica is part of the timestamp. This makes merge commutative, associative and idempotent.
- **`set` and `reset`:** both are ordinary LWW writes. A write whose time is not greater than the existing entry's is ignored. The store always ticks the clock first, so local writes always apply.
- **Unknown keys:** the map never filters keys, so unknown keys pass through untouched.
- **Effective read and `deletedAt` shadowing:**
  - For a key of the form `game/<id>/<name>` where `<name>` is not `deletedAt`, find the entry `game/<id>/deletedAt`.
  - If that entry exists and is not a tombstone, the key counts only when its `time` is **strictly greater** than the `deletedAt` entry's `time`.
  - Shadowing uses the entry timestamp, not the stored value.
  - Global keys, which have no `game/` prefix, are never shadowed.
- Keep the key-prefix parsing in one place, shared with `SettingKey`'s builders, so the layout is defined once.

### `SettingKey.swift`

```swift
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String            // stable dotted name
    public let scope: Scope            // .game / .global
    public enum Scope: Sendable { case game, global }
}
```

- **Storage key layout:**
  - Per-game keys are `game/<gameUUID>/<name>`, using the UUID's canonical lowercase string.
  - Global keys are stored under `<name>`.
  - One internal builder, `storageKey(game: UUID?) -> String?`, that all code uses. A scope mismatch (a game key without a game, or a global key with one) gives nil, which reads as unset and writes nothing, instead of trapping.
  - The layout is parsed in one place, `SettingPath` in `LWWMap.swift`.
  - Enum-typed values are stored as their `String` raw values.
- **Keys defined in 02:**
  - per-game `displayName: SettingKey<String>`
    - It is unset by default. The UI falls back to the folder name of the game's first location, which is not written as a setting until the user edits it.
    - It never enters logs, reports or issues.
  - per-game `routeOverride: SettingKey<String>`, named `route.override`. The value is a route's raw value; absent means Automatic.
  - per-game `deletedAt: SettingKey<Int64>`
    - The value is wall-clock millis, for display only. Shadowing uses the entry's HLC timestamp.
  - per-game fingerprints `fp/<scheme>/<exact>` (`SettingKey.fingerprint(scheme:digest:)`):
    - The digest is the fingerprint's full `exact` hex (already a keyed hash), so the same build shares a key and different builds never collide across devices.
    - `SettingsStore.fingerprintCap` (= `Fingerprint.maxPerGame`) live fingerprints are kept per game and scheme.
  - global `merged/<gameUUID>`: a builder taking the merged-away game's UUID. Its value is the target game's UUID string. The identity sections resolve these links.
- **Reserved namespaces:** document these in a doc comment in `SettingKey.swift`, each with the split that owns it:
  - `fex.*`: split 05
  - `controls.*`: split 04
  - `codePage`: split 09

  02 defines no keys in them. The store never touches them, beyond preserving them like any unknown key.

### `SettingsStore.swift`

`public final class SettingsStore: @unchecked Sendable`. It is file-backed, and all state sits behind one lock.

**Construction**
- It takes:
  - the base directory URL (`…/Application Support/Eikon`)
  - an injectable `now: @Sendable () -> Date`
  - an injectable debounce interval, defaulting to about 0.5 s
- At load:
  1. Load or create the `ReplicaID` from `replica-id`.
  2. Read `settings/<replica>.json` if it exists.
     - The file shape is `{ format: 1, replica, clock, entries, forkedFrom? }`.
     - Read and write it through section 01's `Persisted` rules: a format header and atomic temp-then-rename writes with fsync.
  3. **Fork on own future format.** If the own file's `format` is newer than the app knows:
     - Mint a new `ReplicaID`. Write the new replica file (with `forkedFrom`) synchronously, and only then replace `replica-id`, so a crash can't lose the fork marker.
     - Leave the old file byte-identical and merge its readable entries read-only.
     - Record `forkedFrom = <old replica>` in the new replica's file, so the condition survives restarts.
     - Expose it, for example as `public var forkedFrom: ReplicaID? { get }`.

     The developer section shows this as a warning.
  4. Merge every other `settings/*.json` file in read-only mode. In 02 there are none; split 12 places them there.
     - A future-format peer file is loaded as far as its entries decode and is **never** written.
     - Entries that fail to decode are skipped. They remain in the peer's file untouched.
     - Provide a public `reloadReplicaFiles()` (or similar) that repeats this merge, so split 12 can call it after a sync.
  5. Call `clock.observe` on every merged timestamp.
- **The own file** holds the full merged map this replica knows. `reloadReplicaFiles()` marks it dirty when a merge changed anything. Own-file entries this build can't decode are kept raw and written back unchanged. Adding a top-level or per-entry field requires a `format` bump, because an older build rewrites only the fields it knows.
- **`replica-id` is excluded from backup.** A device restored from another's backup mints its own id and reads the restored settings file as a peer. Merge is idempotent, so re-merging it elsewhere is harmless. It never writes any other replica's file.

**Reads**
- `func value<V>(_ key: SettingKey<V>, game: UUID) -> V?` for game scope, and a global overload without `game`.
- Reads go through `LWWMap.effectiveValue`, so tombstones and `deletedAt` shadowing apply, and are decoded lazily into `V`.
- **A decode failure counts as unset** and returns `nil`, never an error.
- `func isDeleted(game: UUID) -> Bool`: a non-tombstoned `deletedAt` exists for the game.
- `func knownGames() -> [UUID]`: games that have at least one effective key under their prefix and are not deleted. The identity matcher uses it to list candidate games. Deleted games are never candidates.

**Writes**
- `set(_:_:game:)` and `reset(_:game:)`, plus global variants. Each one:
  1. ticks the clock with `now()`
  2. applies the write to the in-memory map immediately, so the next read sees it
  3. schedules persistence
- **Debounced persistence:**
  - A private serial `DispatchQueue` coalesces writes: each write (re)arms a work item roughly 0.5 s out.
  - The work item snapshots the map and clock under the lock, then encodes and writes outside the lock on the queue.
  - Nothing is written on the main thread.
- `func flush()` synchronously writes any pending state and cancels the pending work item. `deinit` also persists pending changes, and a failed write re-arms the debounce.
  - Callers invoke it on scene background and before a game session starts. Those call sites are wired in later sections.
  - Tests use it instead of sleeping.
- **Own-file safety:** when the store forked, it writes only the new replica file. A read-only condition never causes a write to a future-format file.

**Game-wide operations**
- `removeAll(game:)`:
  - It writes `game/<id>/deletedAt` with a fresh tick.
  - The write shadows every older key for that game on every replica once merged.
  - Running cleanup hooks is the library section's job, not the store's.
- `fingerprints(game: UUID, scheme: Int = Fingerprint.currentScheme) -> [Fingerprint]`:
  - It returns the live fingerprints **oldest first** (the order `KnownGame.fingerprints` uses), at most the newest `fingerprintCap`.
  - Values that fail to decode are skipped.
- `addFingerprint(_ fp: Fingerprint, game: UUID)`:
  - The key is `fp/<fp.scheme>/<fp.exact>`: fingerprints are the same when their `exact` values are, as in `IdentityMatcher.adding`. So the same build with a changed engine id (after a blocklist update) replaces its entry, and re-adding refreshes recency.
  - It then tombstones all but the newest `fingerprintCap`. Concurrent adds on two devices can briefly leave more live after a merge; reads cap them, and the next add trims.
- `removeFingerprint(_ fp: Fingerprint, game: UUID)` tombstones the entry with that `exact`. Split uses it.
- `mergeLinks() -> [GameID: GameID]` reads every live `merged/<A>` link, for `IdentityMatcher.resolve`.
- `copySettings(from: UUID, to: UUID, onlyWhereUnset: Bool)`:
  - It copies the source game's effective keys into the target with fresh ticks.
  - It excludes `deletedAt` and `fp/*`, because fingerprints are moved explicitly.
  - Merge uses `onlyWhereUnset: true` ("copy A's settings into B where B has none"). Split uses `false` into a brand-new id, so the new game starts as a fork of the old one's settings.
  - Afterwards the two games are independent.

**Replica id and diagnostics**
- Expose `public var replicaID: ReplicaID { get }` for the developer section.
- `public func snapshot() -> LWWMap` returns the merged map, for diagnostics, tests and split 12.

**Tests:** `SettingsTests.swift` has the 11 behaviors as 11 tests. The persistence test also round-trips `Int.max`.

## Checklist

1. Write `SettingsTests.swift` with the 11 behaviors above. They fail to compile at first.
2. Implement `ReplicaID`, `HybridTimestamp`/`HybridClock`, `JSONValue`, and `LWWEntry`/`LWWMap` with merge and effective reads.
3. Implement `SettingKey`, with its storage-key builders, the 02 keys, the fingerprint slot and merge-link builders, and the reserved-namespace doc comment.
4. Implement `SettingsStore`:
   - load, including the fork path and read-only peer merging
   - typed reads and writes
   - debounced persistence and `flush`
   - the game-wide operations
5. Run `make test-core` until it is green.
