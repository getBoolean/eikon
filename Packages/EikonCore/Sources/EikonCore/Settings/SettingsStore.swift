import CryptoKit
import Foundation

/// Per-game and global settings: a last-writer-wins map ordered by a hybrid clock, one
/// file per replica under `<base>/settings/`. Other replicas' files are merged read-only
/// and never written. Reads and writes are immediate in memory; persistence is debounced
/// on a private serial queue, never on the caller's thread except through `flush()`.
public final class SettingsStore: @unchecked Sendable {
    /// Fingerprint slots kept per game and scheme.
    public static let fingerprintCap = Fingerprint.maxPerGame

    private let directory: URL
    private let now: @Sendable () -> Date
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "eikon.settings.persist")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var map = LWWMap()
    private var clock: HybridClock
    private var ownReplica: ReplicaID
    private var fork: ReplicaID?
    private var dirty = false
    /// Own-file entries this build can't decode, written back unchanged.
    private var undecodable: [String: JSONValue] = [:]
    private var pending: DispatchWorkItem?

    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests).
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }, debounce: TimeInterval = 0.5) throws {
        self.directory = directory
        self.now = now
        self.debounce = debounce

        let stored = try ReplicaID.loadOrCreate(in: directory)
        var replica = stored
        var forkedFrom: ReplicaID?
        var loaded = LWWMap()
        var unknown: [String: JSONValue] = [:]
        var seed: HybridTimestamp?
        let ownURL = Self.fileURL(replica, in: directory)
        if let data = try? Data(contentsOf: ownURL) {
            if Persisted.isReadOnly(data, currentFormat: ReplicaFile.currentFormat) {
                // A newer build owns this file: keep it byte-identical and continue as a new replica.
                forkedFrom = replica
                replica = ReplicaID.random()
            } else if let file = try? JSONDecoder().decode(ReplicaFile.self, from: data) {
                loaded = LWWMap(entries: file.entries)
                unknown = file.undecodable
                forkedFrom = file.forkedFrom
                seed = file.clock
            }
        }
        map = loaded
        undecodable = unknown
        ownReplica = replica
        fork = forkedFrom
        clock = HybridClock(replica: replica, last: seed)
        for entry in map.entries.values { clock.observe(entry.time) }
        mergePeers()
        if replica != stored {
            // Write the new file (with forkedFrom) before switching ids, so a crash can't
            // leave the new id without its fork marker.
            try PersistedFile<ReplicaFile>(url: Self.fileURL(replica, in: directory)).save(currentFile())
            try ReplicaID.store(replica, in: directory)
        }
    }

    deinit {
        pending?.cancel()
        persist()
    }

    public var replicaID: ReplicaID { locked { ownReplica } }

    /// The replica this store forked from because its file came from a newer build.
    public var forkedFrom: ReplicaID? { locked { fork } }

    /// The merged map, for diagnostics and sync.
    public func snapshot() -> LWWMap { locked { map } }

    /// Merges every other replica's file again (after a sync drops new ones in). The own
    /// file is rewritten when that taught this replica anything new.
    public func reloadReplicaFiles() {
        if mergePeers() { locked { markDirty() } }
    }

    // MARK: Reads

    /// nil when unset, reset, shadowed by `deletedAt`, or stored as another type.
    public func value<V>(_ key: SettingKey<V>, game: UUID) -> V? {
        read(key.storageKey(game: game))
    }

    public func value<V>(_ key: SettingKey<V>) -> V? {
        read(key.storageKey(game: nil))
    }

    public func isDeleted(game: UUID) -> Bool {
        locked { map.effectiveEntry(SettingPath.key(game: game, name: SettingPath.deletedAtName)) != nil }
    }

    /// Games with at least one effective key that are not deleted.
    public func knownGames() -> [UUID] {
        locked {
            var games = Set<UUID>()
            for key in map.entries.keys {
                guard let path = SettingPath(key), path.name != SettingPath.deletedAtName,
                      map.effectiveEntry(key) != nil else { continue }
                games.insert(path.game)
            }
            return games.filter { map.effectiveEntry(SettingPath.key(game: $0, name: SettingPath.deletedAtName)) == nil }
                .sorted { $0.uuidString < $1.uuidString }
        }
    }

    // MARK: Writes

    public func set<V>(_ key: SettingKey<V>, _ value: V, game: UUID) {
        write(key.storageKey(game: game), value)
    }

    public func set<V>(_ key: SettingKey<V>, _ value: V) {
        write(key.storageKey(game: nil), value)
    }

    public func reset<V>(_ key: SettingKey<V>, game: UUID) {
        tombstone(key.storageKey(game: game))
    }

    public func reset<V>(_ key: SettingKey<V>) {
        tombstone(key.storageKey(game: nil))
    }

    /// Marks the game deleted: every older key under it, on every replica once merged,
    /// reads as unset. Cleanup hooks are the library's job.
    public func removeAll(game: UUID) {
        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        write(SettingPath.key(game: game, name: SettingPath.deletedAtName), millis)
    }

    // MARK: Fingerprints

    /// Live fingerprints for `scheme`, most recent first, at most `fingerprintCap`;
    /// undecodable ones skipped.
    public func fingerprints<F: Codable & Sendable>(game: UUID, scheme: Int, as type: F.Type) -> [F] {
        locked { live(game: game, scheme: scheme).prefix(Self.fingerprintCap).compactMap { $0.entry.value.decoded(as: F.self) } }
    }

    /// Adds or refreshes a fingerprint (its key is a digest of the value), then tombstones
    /// all but the newest `fingerprintCap`.
    public func addFingerprint<F: Codable & Sendable & Equatable>(_ fingerprint: F, scheme: Int, game: UUID) {
        guard let value = try? JSONValue(encoding: fingerprint), let key = Self.fingerprintKey(value, scheme, game) else { return }
        locked {
            map.set(key, value, at: clock.tick(now: now()))
            for extra in live(game: game, scheme: scheme).dropFirst(Self.fingerprintCap) {
                map.reset(extra.key, at: clock.tick(now: now()))
            }
            markDirty()
        }
    }

    /// Tombstones this fingerprint.
    public func removeFingerprint<F: Codable & Sendable & Equatable>(_ fingerprint: F, scheme: Int, game: UUID) {
        guard let value = try? JSONValue(encoding: fingerprint), let key = Self.fingerprintKey(value, scheme, game) else { return }
        locked {
            guard map.effectiveEntry(key) != nil else { return }
            map.reset(key, at: clock.tick(now: now()))
            markDirty()
        }
    }

    /// Copies the source game's effective settings (not `deletedAt` or fingerprints) into
    /// the target with fresh timestamps; with `onlyWhereUnset`, the target's own values win.
    public func copySettings(from source: UUID, to target: UUID, onlyWhereUnset: Bool) {
        locked {
            let prefix = SettingPath.gamePrefix(source)
            for key in map.entries.keys.sorted() where key.hasPrefix(prefix) {
                guard let path = SettingPath(key), path.name != SettingPath.deletedAtName,
                      !path.name.hasPrefix(SettingPath.fingerprintPrefix),
                      let entry = map.effectiveEntry(key) else { continue }
                let targetKey = SettingPath.key(game: target, name: path.name)
                if onlyWhereUnset, map.effectiveEntry(targetKey) != nil { continue }
                map.set(targetKey, entry.value, at: clock.tick(now: now()))
            }
            markDirty()
        }
    }

    // MARK: Persistence

    /// Writes pending changes now, on the calling thread, and cancels the debounce.
    public func flush() {
        queue.sync { persist() }
    }

    // MARK: Internals

    /// Caller holds the lock. Live fingerprint entries, newest first.
    private func live(game: UUID, scheme: Int) -> [(key: String, entry: LWWEntry)] {
        let prefix = SettingPath.key(game: game, name: "\(SettingPath.fingerprintPrefix)\(scheme)/")
        return map.entries.keys.filter { $0.hasPrefix(prefix) }
            .compactMap { key in map.effectiveEntry(key).map { (key, $0) } }
            .sorted { $0.entry.time > $1.entry.time }
    }

    private static func fingerprintKey(_ value: JSONValue, _ scheme: Int, _ game: UUID) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else { return nil }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return SettingKey.fingerprint(scheme: scheme, digest: digest).storageKey(game: game)
    }

    private func read<V: Decodable>(_ key: String?) -> V? {
        guard let key else { return nil }
        return locked { map.effectiveValue(key) }?.decoded(as: V.self)
    }

    private func write<V: Encodable>(_ key: String?, _ value: V) {
        guard let key, let json = try? JSONValue(encoding: value) else { return }
        locked {
            map.set(key, json, at: clock.tick(now: now()))
            markDirty()
        }
    }

    private func tombstone(_ key: String?) {
        guard let key else { return }
        locked {
            map.reset(key, at: clock.tick(now: now()))
            markDirty()
        }
    }

    /// Caller holds the lock.
    private func markDirty() {
        dirty = true
        schedulePersist()
    }

    /// Caller holds the lock (or is the initializer). Re-arms the debounce.
    private func schedulePersist() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Runs on `queue`: snapshots under the lock, writes outside it.
    private func persist() {
        let snapshot: (ReplicaFile, URL)? = locked {
            pending?.cancel()
            pending = nil
            guard dirty else { return nil }
            dirty = false
            return (currentFile(), Self.fileURL(ownReplica, in: directory))
        }
        guard let (file, url) = snapshot else { return }
        do {
            try PersistedFile<ReplicaFile>(url: url).save(file)
        } catch {
            locked { markDirty() } // retried after the debounce
        }
    }

    /// Caller holds the lock (or is the initializer).
    private func currentFile() -> ReplicaFile {
        var file = ReplicaFile(replica: ownReplica, clock: clock.last, entries: map.entries, forkedFrom: fork)
        file.undecodable = undecodable
        return file
    }

    /// Whether anything changed.
    @discardableResult
    private func mergePeers() -> Bool {
        var changed = false
        let settings = directory.appendingPathComponent("settings", isDirectory: true)
        let own = locked { Self.fileURL(ownReplica, in: directory).lastPathComponent }
        let urls = (try? FileManager.default.contentsOfDirectory(at: settings, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" && url.lastPathComponent != own
            && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ReplicaFile.self, from: data) else { continue }
            let peer = LWWMap(entries: file.entries)
            locked {
                let before = map
                map.merge(peer)
                changed = changed || map != before
                for entry in peer.entries.values { clock.observe(entry.time) }
            }
        }
        return changed
    }

    private static func fileURL(_ replica: ReplicaID, in directory: URL) -> URL {
        directory.appendingPathComponent("settings", isDirectory: true).appendingPathComponent("\(replica).json")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
