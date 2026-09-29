diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/HybridClock.swift b/Packages/EikonCore/Sources/EikonCore/Settings/HybridClock.swift
new file mode 100644
index 0000000..4a8d78c
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/HybridClock.swift
@@ -0,0 +1,48 @@
+import Foundation
+
+/// A hybrid logical timestamp. Totally ordered: wall clock, then counter, then replica.
+public struct HybridTimestamp: Hashable, Comparable, Codable, Sendable {
+    public var wallMillis: Int64
+    public var counter: UInt32
+    public var replica: ReplicaID
+
+    public init(wallMillis: Int64, counter: UInt32, replica: ReplicaID) {
+        self.wallMillis = wallMillis
+        self.counter = counter
+        self.replica = replica
+    }
+
+    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
+        (lhs.wallMillis, lhs.counter, lhs.replica) < (rhs.wallMillis, rhs.counter, rhs.replica)
+    }
+}
+
+/// Issues timestamps that never go backwards and that order after everything observed.
+public struct HybridClock: Sendable, Equatable {
+    public private(set) var last: HybridTimestamp
+
+    public init(replica: ReplicaID, last: HybridTimestamp? = nil) {
+        self.last = HybridTimestamp(wallMillis: last?.wallMillis ?? 0, counter: last?.counter ?? 0, replica: replica)
+    }
+
+    public var replica: ReplicaID { last.replica }
+
+    public mutating func tick(now: Date) -> HybridTimestamp {
+        let wall = max(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)), last.wallMillis)
+        if wall > last.wallMillis {
+            last = HybridTimestamp(wallMillis: wall, counter: 0, replica: replica)
+        } else if last.counter == .max {
+            last = HybridTimestamp(wallMillis: wall + 1, counter: 0, replica: replica)
+        } else {
+            last.counter += 1
+        }
+        return last
+    }
+
+    /// The next tick orders after `remote`, however far in the future it is.
+    public mutating func observe(_ remote: HybridTimestamp) {
+        if (remote.wallMillis, remote.counter) > (last.wallMillis, last.counter) {
+            last = HybridTimestamp(wallMillis: remote.wallMillis, counter: remote.counter, replica: replica)
+        }
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/JSONValue.swift b/Packages/EikonCore/Sources/EikonCore/Settings/JSONValue.swift
new file mode 100644
index 0000000..ff9eade
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/JSONValue.swift
@@ -0,0 +1,51 @@
+import Foundation
+
+/// Any JSON value: how settings are held, so keys this build doesn't know round-trip.
+public enum JSONValue: Codable, Sendable, Equatable {
+    case null
+    case bool(Bool)
+    case number(Double)
+    case string(String)
+    case array([JSONValue])
+    case object([String: JSONValue])
+
+    public init(from decoder: any Decoder) throws {
+        let container = try decoder.singleValueContainer()
+        if container.decodeNil() {
+            self = .null
+        } else if let value = try? container.decode(Bool.self) {
+            self = .bool(value)
+        } else if let value = try? container.decode(Double.self) {
+            self = .number(value)
+        } else if let value = try? container.decode(String.self) {
+            self = .string(value)
+        } else if let value = try? container.decode([JSONValue].self) {
+            self = .array(value)
+        } else {
+            self = .object(try container.decode([String: JSONValue].self))
+        }
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.singleValueContainer()
+        switch self {
+        case .null: try container.encodeNil()
+        case .bool(let value): try container.encode(value)
+        case .number(let value): try container.encode(value)
+        case .string(let value): try container.encode(value)
+        case .array(let value): try container.encode(value)
+        case .object(let value): try container.encode(value)
+        }
+    }
+
+    /// Any Codable value as JSON. Integers are exact up to 2^53.
+    public init<Value: Encodable>(encoding value: Value) throws {
+        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
+    }
+
+    /// This JSON as a `Value`, or nil when it doesn't decode as one.
+    public func decoded<Value: Decodable>(as type: Value.Type) -> Value? {
+        guard let data = try? JSONEncoder().encode(self) else { return nil }
+        return try? JSONDecoder().decode(Value.self, from: data)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/LWWMap.swift b/Packages/EikonCore/Sources/EikonCore/Settings/LWWMap.swift
new file mode 100644
index 0000000..cbced23
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/LWWMap.swift
@@ -0,0 +1,90 @@
+import Foundation
+
+/// One register of the map: a value or a tombstone, stamped with its write time.
+public struct LWWEntry: Codable, Sendable, Equatable {
+    /// `.null` for tombstones.
+    public var value: JSONValue
+    public var time: HybridTimestamp
+    public var isTombstone: Bool
+
+    public init(value: JSONValue, time: HybridTimestamp, isTombstone: Bool) {
+        self.value = value
+        self.time = time
+        self.isTombstone = isTombstone
+    }
+}
+
+/// A per-key last-writer-wins map. Merge keeps the later entry per key, so it is
+/// commutative, associative and idempotent; keys are never filtered.
+public struct LWWMap: Codable, Sendable, Equatable {
+    public private(set) var entries: [String: LWWEntry]
+
+    public init(entries: [String: LWWEntry] = [:]) {
+        self.entries = entries
+    }
+
+    /// Ignored unless `time` is later than the key's current entry.
+    public mutating func set(_ key: String, _ value: JSONValue, at time: HybridTimestamp) {
+        apply(key, LWWEntry(value: value, time: time, isTombstone: false))
+    }
+
+    /// Writes a tombstone, so the reset propagates and beats older sets.
+    public mutating func reset(_ key: String, at time: HybridTimestamp) {
+        apply(key, LWWEntry(value: .null, time: time, isTombstone: true))
+    }
+
+    public mutating func merge(_ other: LWWMap) {
+        for (key, entry) in other.entries {
+            apply(key, entry)
+        }
+    }
+
+    /// nil when absent, tombstoned, or shadowed by the game's `deletedAt`.
+    public func effectiveValue(_ key: String) -> JSONValue? {
+        effectiveEntry(key)?.value
+    }
+
+    /// The entry, when it counts: a game key counts only if written after the game's
+    /// live `deletedAt` entry. Global keys are never shadowed.
+    public func effectiveEntry(_ key: String) -> LWWEntry? {
+        guard let entry = entries[key], !entry.isTombstone else { return nil }
+        if let path = SettingPath(key), path.name != SettingPath.deletedAtName,
+           let deleted = entries[SettingPath.key(game: path.game, name: SettingPath.deletedAtName)],
+           !deleted.isTombstone, entry.time <= deleted.time {
+            return nil
+        }
+        return entry
+    }
+
+    private mutating func apply(_ key: String, _ entry: LWWEntry) {
+        if let existing = entries[key], entry.time <= existing.time { return }
+        entries[key] = entry
+    }
+}
+
+/// The storage-key layout, defined once: per-game keys are `game/<uuid>/<name>` with the
+/// UUID lowercase; global keys are the bare name.
+struct SettingPath: Equatable {
+    static let deletedAtName = "deletedAt"
+    static let fingerprintPrefix = "fp/"
+    private static let gamePrefix = "game/"
+
+    let game: UUID
+    let name: String
+
+    init?(_ key: String) {
+        guard key.hasPrefix(Self.gamePrefix) else { return nil }
+        let rest = key.dropFirst(Self.gamePrefix.count)
+        guard let slash = rest.firstIndex(of: "/"), let game = UUID(uuidString: String(rest[..<slash])) else { return nil }
+        self.game = game
+        self.name = String(rest[rest.index(after: slash)...])
+    }
+
+    static func key(game: UUID, name: String) -> String {
+        "\(gamePrefix)\(game.uuidString.lowercased())/\(name)"
+    }
+
+    static func gamePrefix(_ game: UUID) -> String {
+        "\(gamePrefix)\(game.uuidString.lowercased())/"
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaFile.swift b/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaFile.swift
new file mode 100644
index 0000000..45d3650
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaFile.swift
@@ -0,0 +1,41 @@
+import Foundation
+
+/// `settings/<replica>.json`: one replica's full merged view. Decodes tolerantly, so a
+/// file from a newer build loads as far as its fields and entries decode.
+struct ReplicaFile: PersistedDocument {
+    static let currentFormat = 1
+
+    var replica: ReplicaID?
+    var clock: HybridTimestamp?
+    var entries: [String: LWWEntry]
+    var forkedFrom: ReplicaID?
+
+    init(replica: ReplicaID, clock: HybridTimestamp, entries: [String: LWWEntry], forkedFrom: ReplicaID?) {
+        self.replica = replica
+        self.clock = clock
+        self.entries = entries
+        self.forkedFrom = forkedFrom
+    }
+
+    private enum CodingKeys: String, CodingKey {
+        case replica, clock, entries, forkedFrom
+    }
+
+    /// Entries that fail to decode are skipped; they stay in the file on disk.
+    init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: CodingKeys.self)
+        replica = try? container.decodeIfPresent(ReplicaID.self, forKey: .replica)
+        clock = try? container.decodeIfPresent(HybridTimestamp.self, forKey: .clock)
+        forkedFrom = try? container.decodeIfPresent(ReplicaID.self, forKey: .forkedFrom)
+        let raw = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .entries)) ?? [:]
+        entries = raw.compactMapValues { $0.decoded(as: LWWEntry.self) }
+    }
+
+    func encode(to encoder: any Encoder) throws {
+        var container = encoder.container(keyedBy: CodingKeys.self)
+        try container.encodeIfPresent(replica, forKey: .replica)
+        try container.encodeIfPresent(clock, forKey: .clock)
+        try container.encode(entries, forKey: .entries)
+        try container.encodeIfPresent(forkedFrom, forKey: .forkedFrom)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaID.swift b/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaID.swift
new file mode 100644
index 0000000..3e838ae
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/ReplicaID.swift
@@ -0,0 +1,49 @@
+import Foundation
+
+/// One device's (one install's) identity in the settings files. Random, created once.
+public struct ReplicaID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
+    public let uuid: UUID
+
+    public init(uuid: UUID) {
+        self.uuid = uuid
+    }
+
+    public static func random() -> ReplicaID {
+        ReplicaID(uuid: UUID())
+    }
+
+    public var description: String { uuid.uuidString.lowercased() }
+
+    public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
+        lhs.description < rhs.description
+    }
+
+    /// Coded as the bare UUID string.
+    public init(from decoder: any Decoder) throws {
+        uuid = try decoder.singleValueContainer().decode(UUID.self)
+    }
+
+    public func encode(to encoder: any Encoder) throws {
+        var container = encoder.singleValueContainer()
+        try container.encode(uuid)
+    }
+
+    static let fileName = "replica-id"
+
+    /// Reads `replica-id` in `directory`; a missing or unreadable file gets a new random id.
+    public static func loadOrCreate(in directory: URL) throws -> ReplicaID {
+        let url = directory.appendingPathComponent(fileName)
+        if let text = try? String(contentsOf: url, encoding: .utf8),
+           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
+            return ReplicaID(uuid: uuid)
+        }
+        let id = random()
+        try store(id, in: directory)
+        return id
+    }
+
+    /// Replaces the stored id, so a fork survives restarts.
+    static func store(_ id: ReplicaID, in directory: URL) throws {
+        try Persisted.writeAtomically(Data(id.description.utf8), to: directory.appendingPathComponent(fileName))
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/SettingKey.swift b/Packages/EikonCore/Sources/EikonCore/Settings/SettingKey.swift
new file mode 100644
index 0000000..0080edd
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/SettingKey.swift
@@ -0,0 +1,61 @@
+import Foundation
+
+/// A typed setting. Per-game keys are stored as `game/<uuid>/<name>`, global keys as
+/// `<name>`; enum values are stored as their raw strings.
+///
+/// Reserved namespaces, owned by later splits (02 defines no keys there; the store keeps
+/// them like any unknown key):
+/// - `fex.*`: split 05
+/// - `controls.*`: split 04
+/// - `codePage`: split 09
+public struct SettingKey<Value: Codable & Sendable>: Sendable {
+    public enum Scope: Sendable { case game, global }
+
+    /// A stable dotted name.
+    public let name: String
+    public let scope: Scope
+
+    public init(name: String, scope: Scope) {
+        self.name = name
+        self.scope = scope
+    }
+
+    /// The key in the map. A game key needs a game; a global key takes none.
+    func storageKey(game: UUID?) -> String {
+        switch scope {
+        case .game:
+            guard let game else { preconditionFailure("a per-game setting needs a game") }
+            return SettingPath.key(game: game, name: name)
+        case .global:
+            precondition(game == nil, "a global setting takes no game")
+            return name
+        }
+    }
+}
+
+extension SettingKey where Value == String {
+    /// Unset by default: the UI falls back to the first location's folder name. A title
+    /// in practice, so it never enters logs, reports or issues.
+    public static var displayName: SettingKey<String> { SettingKey(name: "displayName", scope: .game) }
+
+    /// A route's raw value; absent (or unknown) means Automatic.
+    public static var routeOverride: SettingKey<String> { SettingKey(name: "route.override", scope: .game) }
+
+    /// Global `merged/<uuid>`: the game this merged-away game now resolves to, as a UUID string.
+    public static func merged(_ game: UUID) -> SettingKey<String> {
+        SettingKey(name: "merged/\(game.uuidString.lowercased())", scope: .global)
+    }
+}
+
+extension SettingKey where Value == Int64 {
+    /// Wall-clock millis, for display only; shadowing uses the entry's timestamp.
+    public static var deletedAt: SettingKey<Int64> { SettingKey(name: SettingPath.deletedAtName, scope: .game) }
+}
+
+extension SettingKey where Value == JSONValue {
+    /// Fingerprint slot `fp/<scheme>/<n>`, n in `0..<SettingsStore.fingerprintCap`. One key per
+    /// slot, so two devices adding fingerprints never overwrite a whole list.
+    public static func fingerprintSlot(scheme: Int, _ n: Int) -> SettingKey<JSONValue> {
+        SettingKey(name: "\(SettingPath.fingerprintPrefix)\(scheme)/\(n)", scope: .game)
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift b/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift
new file mode 100644
index 0000000..3d45b3b
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Settings/SettingsStore.swift
@@ -0,0 +1,279 @@
+import Foundation
+
+/// Per-game and global settings: a last-writer-wins map ordered by a hybrid clock, one
+/// file per replica under `<base>/settings/`. Other replicas' files are merged read-only
+/// and never written. Reads and writes are immediate in memory; persistence is debounced
+/// on a private serial queue, never on the caller's thread except through `flush()`.
+public final class SettingsStore: @unchecked Sendable {
+    /// Fingerprint slots kept per game and scheme.
+    public static let fingerprintCap = Fingerprint.maxPerGame
+
+    private let directory: URL
+    private let now: @Sendable () -> Date
+    private let debounce: TimeInterval
+    private let queue = DispatchQueue(label: "eikon.settings.persist")
+    private let lock = NSLock()
+
+    // Guarded by `lock`.
+    private var map = LWWMap()
+    private var clock: HybridClock
+    private var ownReplica: ReplicaID
+    private var fork: ReplicaID?
+    private var dirty = false
+    private var pending: DispatchWorkItem?
+
+    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests).
+    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }, debounce: TimeInterval = 0.5) throws {
+        self.directory = directory
+        self.now = now
+        self.debounce = debounce
+
+        var replica = try ReplicaID.loadOrCreate(in: directory)
+        var forkedFrom: ReplicaID?
+        var loaded = LWWMap()
+        var seed: HybridTimestamp?
+        let ownURL = Self.fileURL(replica, in: directory)
+        if let data = try? Data(contentsOf: ownURL) {
+            if Persisted.isReadOnly(data, currentFormat: ReplicaFile.currentFormat) {
+                // A newer build owns this file: keep it byte-identical and continue as a new replica.
+                forkedFrom = replica
+                replica = ReplicaID.random()
+                try ReplicaID.store(replica, in: directory)
+            } else if let file = try? JSONDecoder().decode(ReplicaFile.self, from: data) {
+                loaded = LWWMap(entries: file.entries)
+                forkedFrom = file.forkedFrom
+                seed = file.clock
+            }
+        }
+        map = loaded
+        ownReplica = replica
+        fork = forkedFrom
+        clock = HybridClock(replica: replica, last: seed)
+        for entry in map.entries.values { clock.observe(entry.time) }
+        mergePeers()
+        if forkedFrom != nil, (try? Data(contentsOf: Self.fileURL(replica, in: directory))) == nil {
+            dirty = true
+            schedulePersist()
+        }
+    }
+
+    public var replicaID: ReplicaID { locked { ownReplica } }
+
+    /// The replica this store forked from because its file came from a newer build.
+    public var forkedFrom: ReplicaID? { locked { fork } }
+
+    /// The merged map, for diagnostics and sync.
+    public func snapshot() -> LWWMap { locked { map } }
+
+    /// Merges every other replica's file again (after a sync drops new ones in).
+    public func reloadReplicaFiles() {
+        mergePeers()
+    }
+
+    // MARK: Reads
+
+    /// nil when unset, reset, shadowed by `deletedAt`, or stored as another type.
+    public func value<V>(_ key: SettingKey<V>, game: UUID) -> V? {
+        read(key.storageKey(game: game))
+    }
+
+    public func value<V>(_ key: SettingKey<V>) -> V? {
+        read(key.storageKey(game: nil))
+    }
+
+    public func isDeleted(game: UUID) -> Bool {
+        locked { map.effectiveEntry(SettingKey.deletedAt.storageKey(game: game)) != nil }
+    }
+
+    /// Games with at least one effective key that are not deleted.
+    public func knownGames() -> [UUID] {
+        locked {
+            var games = Set<UUID>()
+            for key in map.entries.keys {
+                guard let path = SettingPath(key), path.name != SettingPath.deletedAtName,
+                      map.effectiveEntry(key) != nil else { continue }
+                games.insert(path.game)
+            }
+            return games.filter { map.effectiveEntry(SettingKey.deletedAt.storageKey(game: $0)) == nil }
+                .sorted { $0.uuidString < $1.uuidString }
+        }
+    }
+
+    // MARK: Writes
+
+    public func set<V>(_ key: SettingKey<V>, _ value: V, game: UUID) {
+        write(key.storageKey(game: game), value)
+    }
+
+    public func set<V>(_ key: SettingKey<V>, _ value: V) {
+        write(key.storageKey(game: nil), value)
+    }
+
+    public func reset<V>(_ key: SettingKey<V>, game: UUID) {
+        tombstone(key.storageKey(game: game))
+    }
+
+    public func reset<V>(_ key: SettingKey<V>) {
+        tombstone(key.storageKey(game: nil))
+    }
+
+    /// Marks the game deleted: every older key under it, on every replica once merged,
+    /// reads as unset. Cleanup hooks are the library's job.
+    public func removeAll(game: UUID) {
+        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
+        write(SettingKey.deletedAt.storageKey(game: game), millis)
+    }
+
+    // MARK: Fingerprints
+
+    /// Effective fingerprint slots for `scheme`, most recent first; undecodable slots skipped.
+    public func fingerprints<F: Codable & Sendable>(game: UUID, scheme: Int, as type: F.Type) -> [F] {
+        locked {
+            slots(game: game, scheme: scheme)
+                .compactMap { slot in slot.entry.map { ($0.time, $0.value) } }
+                .sorted { $0.0 > $1.0 }
+                .compactMap { $0.1.decoded(as: F.self) }
+        }
+    }
+
+    /// Keeps the most recent `fingerprintCap`: an equal value's slot is refreshed, else the
+    /// first empty slot is used, else the oldest slot is overwritten.
+    public func addFingerprint<F: Codable & Sendable & Equatable>(_ fingerprint: F, scheme: Int, game: UUID) {
+        guard let value = try? JSONValue(encoding: fingerprint) else { return }
+        locked {
+            let slots = slots(game: game, scheme: scheme)
+            let target = slots.first { $0.entry?.value.decoded(as: F.self) == fingerprint }
+                ?? slots.first { $0.entry == nil }
+                ?? slots.min { $0.entry!.time < $1.entry!.time }!
+            map.set(target.key, value, at: clock.tick(now: now()))
+            markDirty()
+        }
+    }
+
+    /// Tombstones the slot holding an equal value.
+    public func removeFingerprint<F: Codable & Sendable & Equatable>(_ fingerprint: F, scheme: Int, game: UUID) {
+        locked {
+            guard let slot = slots(game: game, scheme: scheme)
+                .first(where: { $0.entry?.value.decoded(as: F.self) == fingerprint }) else { return }
+            map.reset(slot.key, at: clock.tick(now: now()))
+            markDirty()
+        }
+    }
+
+    /// Copies the source game's effective settings (not `deletedAt` or fingerprints) into
+    /// the target with fresh timestamps; with `onlyWhereUnset`, the target's own values win.
+    public func copySettings(from source: UUID, to target: UUID, onlyWhereUnset: Bool) {
+        locked {
+            let prefix = SettingPath.gamePrefix(source)
+            for key in map.entries.keys.sorted() where key.hasPrefix(prefix) {
+                guard let path = SettingPath(key), path.name != SettingPath.deletedAtName,
+                      !path.name.hasPrefix(SettingPath.fingerprintPrefix),
+                      let entry = map.effectiveEntry(key) else { continue }
+                let targetKey = SettingPath.key(game: target, name: path.name)
+                if onlyWhereUnset, map.effectiveEntry(targetKey) != nil { continue }
+                map.set(targetKey, entry.value, at: clock.tick(now: now()))
+            }
+            markDirty()
+        }
+    }
+
+    // MARK: Persistence
+
+    /// Writes pending changes now, on the calling thread, and cancels the debounce.
+    public func flush() {
+        queue.sync { persist() }
+    }
+
+    // MARK: Internals
+
+    private struct Slot {
+        let key: String
+        /// nil when empty, tombstoned or shadowed.
+        let entry: LWWEntry?
+    }
+
+    /// Caller holds the lock.
+    private func slots(game: UUID, scheme: Int) -> [Slot] {
+        (0..<Self.fingerprintCap).map { n in
+            let key = SettingKey.fingerprintSlot(scheme: scheme, n).storageKey(game: game)
+            return Slot(key: key, entry: map.effectiveEntry(key))
+        }
+    }
+
+    private func read<V: Decodable>(_ key: String) -> V? {
+        locked { map.effectiveValue(key) }?.decoded(as: V.self)
+    }
+
+    private func write<V: Encodable>(_ key: String, _ value: V) {
+        guard let json = try? JSONValue(encoding: value) else { return }
+        locked {
+            map.set(key, json, at: clock.tick(now: now()))
+            markDirty()
+        }
+    }
+
+    private func tombstone(_ key: String) {
+        locked {
+            map.reset(key, at: clock.tick(now: now()))
+            markDirty()
+        }
+    }
+
+    /// Caller holds the lock.
+    private func markDirty() {
+        dirty = true
+        schedulePersist()
+    }
+
+    /// Caller holds the lock (or is the initializer). Re-arms the debounce.
+    private func schedulePersist() {
+        pending?.cancel()
+        let item = DispatchWorkItem { [weak self] in self?.persist() }
+        pending = item
+        queue.asyncAfter(deadline: .now() + debounce, execute: item)
+    }
+
+    /// Runs on `queue`: snapshots under the lock, writes outside it.
+    private func persist() {
+        let snapshot: (ReplicaFile, URL)? = locked {
+            pending?.cancel()
+            pending = nil
+            guard dirty else { return nil }
+            dirty = false
+            return (ReplicaFile(replica: ownReplica, clock: clock.last, entries: map.entries, forkedFrom: fork),
+                    Self.fileURL(ownReplica, in: directory))
+        }
+        guard let (file, url) = snapshot else { return }
+        do {
+            try PersistedFile<ReplicaFile>(url: url).save(file)
+        } catch {
+            locked { dirty = true }
+        }
+    }
+
+    private func mergePeers() {
+        let settings = directory.appendingPathComponent("settings", isDirectory: true)
+        let own = locked { Self.fileURL(ownReplica, in: directory).lastPathComponent }
+        let urls = (try? FileManager.default.contentsOfDirectory(at: settings, includingPropertiesForKeys: nil)) ?? []
+        for url in urls where url.pathExtension == "json" && url.lastPathComponent != own
+            && !url.lastPathComponent.hasPrefix(".") {
+            guard let data = try? Data(contentsOf: url),
+                  let file = try? JSONDecoder().decode(ReplicaFile.self, from: data) else { continue }
+            let peer = LWWMap(entries: file.entries)
+            locked {
+                map.merge(peer)
+                for entry in peer.entries.values { clock.observe(entry.time) }
+            }
+        }
+    }
+
+    private static func fileURL(_ replica: ReplicaID, in directory: URL) -> URL {
+        directory.appendingPathComponent("settings", isDirectory: true).appendingPathComponent("\(replica).json")
+    }
+
+    private func locked<T>(_ body: () throws -> T) rethrows -> T {
+        lock.lock()
+        defer { lock.unlock() }
+        return try body()
+    }
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/SettingsTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/SettingsTests.swift
new file mode 100644
index 0000000..a9b9e19
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/SettingsTests.swift
@@ -0,0 +1,259 @@
+import Foundation
+import Testing
+import EikonCore
+
+// MARK: Fakes
+
+/// A settable wall clock.
+private final class TestClock: @unchecked Sendable {
+    private let lock = NSLock()
+    private var current = Date(timeIntervalSince1970: 1_700_000_000)
+
+    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
+
+    func advance(_ seconds: TimeInterval) {
+        lock.withLock { current += seconds }
+    }
+}
+
+private func withTempDir(_ body: (URL) throws -> Void) throws {
+    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
+    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
+    defer { try? FileManager.default.removeItem(at: dir) }
+    try body(dir)
+}
+
+private func store(_ dir: URL, _ clock: TestClock = TestClock()) throws -> SettingsStore {
+    try SettingsStore(directory: dir, now: clock.now, debounce: 3600)
+}
+
+private func ownFile(_ store: SettingsStore, in dir: URL) -> URL {
+    dir.appendingPathComponent("settings/\(store.replicaID).json")
+}
+
+/// Rewrites a replica file's `format` so it looks like it came from a newer build.
+private func makeFutureFormat(_ url: URL) throws {
+    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
+    object["format"] = 999
+    try JSONSerialization.data(withJSONObject: object).write(to: url)
+}
+
+/// Another device's replica file, written by a store in its own directory and copied in.
+private func peerFile(into dir: URL, clock: TestClock = TestClock(), _ writes: (SettingsStore) -> Void) throws -> URL {
+    let peerDir = dir.appendingPathComponent("peer-\(UUID().uuidString)")
+    let peer = try store(peerDir, clock)
+    writes(peer)
+    peer.flush()
+    let destination = dir.appendingPathComponent("settings/\(peer.replicaID).json")
+    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
+    try FileManager.default.copyItem(at: ownFile(peer, in: peerDir), to: destination)
+    return destination
+}
+
+private let name = SettingKey<String>(name: "sample.name", scope: .game)
+private let count = SettingKey<Int>(name: "sample.count", scope: .game)
+
+/// A seeded generator, so the property test is deterministic.
+private struct SplitMix64: RandomNumberGenerator {
+    var state: UInt64
+    mutating func next() -> UInt64 {
+        state &+= 0x9E37_79B9_7F4A_7C15
+        var z = state
+        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
+        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
+        return z ^ (z >> 31)
+    }
+}
+
+// MARK: Merge laws
+
+@Test func mergeIsCommutativeAssociativeAndIdempotent() {
+    var random = SplitMix64(state: 42)
+    let game = UUID()
+    let keys = ["game/\(game.uuidString.lowercased())/a", "game/\(game.uuidString.lowercased())/b",
+                "game/\(game.uuidString.lowercased())/deletedAt", "global.c"]
+    let maps: [LWWMap] = (0..<3).map { _ in
+        var clock = HybridClock(replica: .random())
+        var map = LWWMap()
+        var wall = 1_000_000.0
+        for _ in 0..<200 {
+            wall += Double(Int.random(in: -50...100, using: &random)) // includes backwards jumps
+            let time = clock.tick(now: Date(timeIntervalSince1970: wall))
+            let key = keys.randomElement(using: &random)!
+            if Bool.random(using: &random) {
+                map.set(key, .number(Double(Int.random(in: 0...9, using: &random))), at: time)
+            } else {
+                map.reset(key, at: time)
+            }
+        }
+        return map
+    }
+    func merged(_ list: [LWWMap]) -> LWWMap {
+        list.reduce(into: LWWMap()) { $0.merge($1) }
+    }
+    let reference = merged(maps)
+    for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
+        #expect(merged(order.map { maps[$0] }) == reference)
+    }
+    var left = maps[0]; left.merge(maps[1]); left.merge(maps[2])
+    var right = maps[1]; right.merge(maps[2])
+    var grouped = maps[0]; grouped.merge(right)
+    #expect(left == grouped)
+
+    var again = reference
+    again.merge(maps[1])
+    again.merge(reference)
+    #expect(again == reference)
+}
+
+// MARK: Store behaviour
+
+@Test func newerResetBeatsOlderSetAndNewerSetBeatsReset() throws {
+    try withTempDir { dir in
+        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
+        settings.set(name, "first", game: game)
+        clock.advance(1)
+        settings.reset(name, game: game)
+        #expect(settings.value(name, game: game) == nil)
+        clock.advance(1)
+        settings.set(name, "second", game: game)
+        #expect(settings.value(name, game: game) == "second")
+    }
+}
+
+@Test func unknownKeysRoundTrip() throws {
+    try withTempDir { dir in
+        let unknown = SettingKey<[String: Int]>(name: "fex.fromANewerBuild", scope: .global)
+        let newer = try store(dir)
+        newer.set(unknown, ["x": 1])
+        newer.flush()
+        let before = try #require(newer.snapshot().entries[unknown.name])
+
+        let current = try store(dir)
+        current.set(name, "unrelated", game: UUID())
+        current.flush()
+        #expect(try store(dir).snapshot().entries[unknown.name] == before)
+    }
+}
+
+@Test func clockNeverGoesBackwards() throws {
+    try withTempDir { dir in
+        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
+        settings.set(name, "earlier", game: game)
+        clock.advance(-3600)
+        settings.set(name, "later", game: game)
+        #expect(settings.value(name, game: game) == "later")
+    }
+}
+
+@Test func localWriteOrdersAfterAnObservedFutureTimestamp() throws {
+    try withTempDir { dir in
+        let future = TestClock(), game = UUID()
+        future.advance(10 * 365 * 86_400)
+        _ = try peerFile(into: dir, clock: future) { $0.set(name, "remote", game: game) }
+
+        let settings = try store(dir)
+        #expect(settings.value(name, game: game) == "remote")
+        settings.set(name, "local", game: game)
+        #expect(settings.value(name, game: game) == "local")
+    }
+}
+
+@Test func peerFileInAFutureFormatIsMergedButNeverRewritten() throws {
+    try withTempDir { dir in
+        let game = UUID()
+        let peer = try peerFile(into: dir) { $0.set(name, "from-peer", game: game) }
+        try makeFutureFormat(peer)
+        let before = try Data(contentsOf: peer)
+
+        let settings = try store(dir)
+        #expect(settings.value(name, game: game) == "from-peer")
+        settings.set(count, 3, game: game)
+        settings.flush()
+        #expect(try Data(contentsOf: peer) == before)
+    }
+}
+
+@Test func ownFileInAFutureFormatForksToANewReplica() throws {
+    try withTempDir { dir in
+        let game = UUID()
+        let original = try store(dir)
+        original.set(name, "kept", game: game)
+        original.flush()
+        let oldFile = ownFile(original, in: dir)
+        try makeFutureFormat(oldFile)
+        let before = try Data(contentsOf: oldFile)
+
+        let forked = try store(dir)
+        #expect(forked.forkedFrom == original.replicaID)
+        #expect(forked.replicaID != original.replicaID)
+        #expect(forked.value(name, game: game) == "kept")
+        forked.set(count, 1, game: game)
+        forked.flush()
+        #expect(try Data(contentsOf: oldFile) == before)
+        #expect(FileManager.default.fileExists(atPath: ownFile(forked, in: dir).path))
+
+        let reopened = try store(dir)
+        #expect(reopened.replicaID == forked.replicaID)
+        #expect(reopened.forkedFrom == original.replicaID)
+    }
+}
+
+@Test func deletedAtHidesOlderKeysOnlyForThatGame() throws {
+    try withTempDir { dir in
+        let clock = TestClock(), game = UUID(), other = UUID()
+        _ = try peerFile(into: dir, clock: clock) { $0.set(count, 7, game: game) }
+        let settings = try store(dir, clock)
+        settings.set(name, "before", game: game)
+        settings.set(name, "untouched", game: other)
+        clock.advance(1)
+
+        settings.removeAll(game: game)
+        #expect(settings.isDeleted(game: game))
+        #expect(settings.value(name, game: game) == nil)
+        #expect(settings.value(count, game: game) == nil)
+        #expect(settings.value(name, game: other) == "untouched")
+        #expect(!settings.knownGames().contains(game))
+
+        clock.advance(1)
+        settings.set(name, "after", game: game)
+        #expect(settings.value(name, game: game) == "after")
+    }
+}
+
+@Test func valueOfTheWrongTypeReadsAsUnset() throws {
+    try withTempDir { dir in
+        let settings = try store(dir), game = UUID()
+        settings.set(SettingKey<String>(name: count.name, scope: .game), "not a number", game: game)
+        #expect(settings.value(count, game: game) == nil)
+    }
+}
+
+@Test func writesPersistAcrossInstances() throws {
+    try withTempDir { dir in
+        let game = UUID()
+        let first = try store(dir)
+        first.set(name, "saved", game: game)
+        first.set(SettingKey<String>.merged(game), UUID().uuidString)
+        first.flush()
+
+        let second = try store(dir)
+        #expect(second.replicaID == first.replicaID)
+        #expect(second.value(name, game: game) == "saved")
+        #expect(second.value(SettingKey<String>.merged(game)) == first.value(SettingKey<String>.merged(game)))
+    }
+}
+
+@Test func fingerprintSlotsKeepTheMostRecent() throws {
+    try withTempDir { dir in
+        let clock = TestClock(), settings = try store(dir, clock), game = UUID()
+        let added = (0..<(SettingsStore.fingerprintCap + 2)).map { "fingerprint-\($0)" }
+        for fingerprint in added {
+            settings.addFingerprint(fingerprint, scheme: 1, game: game)
+            clock.advance(1)
+        }
+        let kept = settings.fingerprints(game: game, scheme: 1, as: String.self)
+        #expect(kept == Array(added.suffix(SettingsStore.fingerprintCap).reversed()))
+        #expect(!kept.contains(added[0]))
+    }
+}
