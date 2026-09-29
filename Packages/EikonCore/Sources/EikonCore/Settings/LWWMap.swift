import Foundation

/// One register of the map: a value or a tombstone, stamped with its write time.
public struct LWWEntry: Codable, Sendable, Equatable {
    /// `.null` for tombstones.
    public var value: JSONValue
    public var time: HybridTimestamp
    public var isTombstone: Bool

    public init(value: JSONValue, time: HybridTimestamp, isTombstone: Bool) {
        self.value = value
        self.time = time
        self.isTombstone = isTombstone
    }
}

/// A per-key last-writer-wins map. Merge keeps the later entry per key, so it is
/// commutative, associative and idempotent; keys are never filtered.
public struct LWWMap: Codable, Sendable, Equatable {
    public private(set) var entries: [String: LWWEntry]

    public init(entries: [String: LWWEntry] = [:]) {
        self.entries = entries
    }

    /// Ignored unless `time` is later than the key's current entry.
    public mutating func set(_ key: String, _ value: JSONValue, at time: HybridTimestamp) {
        apply(key, LWWEntry(value: value, time: time, isTombstone: false))
    }

    /// Writes a tombstone, so the reset propagates and beats older sets.
    public mutating func reset(_ key: String, at time: HybridTimestamp) {
        apply(key, LWWEntry(value: .null, time: time, isTombstone: true))
    }

    public mutating func merge(_ other: LWWMap) {
        for (key, entry) in other.entries {
            apply(key, entry)
        }
    }

    /// nil when absent, tombstoned, or shadowed by the game's `deletedAt`.
    public func effectiveValue(_ key: String) -> JSONValue? {
        effectiveEntry(key)?.value
    }

    /// The entry, when it counts: a game key counts only if written after the game's
    /// live `deletedAt` entry. Global keys are never shadowed.
    public func effectiveEntry(_ key: String) -> LWWEntry? {
        guard let entry = entries[key], !entry.isTombstone else { return nil }
        if let path = SettingPath(key), path.name != SettingPath.deletedAtName,
           let deleted = entries[SettingPath.key(game: path.game, name: SettingPath.deletedAtName)],
           !deleted.isTombstone, entry.time <= deleted.time {
            return nil
        }
        return entry
    }

    private mutating func apply(_ key: String, _ entry: LWWEntry) {
        if let existing = entries[key], entry.time <= existing.time { return }
        entries[key] = entry
    }
}

/// The storage-key layout, defined once: per-game keys are `game/<uuid>/<name>` with the
/// UUID lowercase; global keys are the bare name.
struct SettingPath: Equatable {
    static let deletedAtName = "deletedAt"
    static let fingerprintPrefix = "fp/"
    private static let gamePrefix = "game/"

    let game: UUID
    let name: String

    init?(_ key: String) {
        guard key.hasPrefix(Self.gamePrefix) else { return nil }
        let rest = key.dropFirst(Self.gamePrefix.count)
        guard let slash = rest.firstIndex(of: "/"), let game = UUID(uuidString: String(rest[..<slash])) else { return nil }
        self.game = game
        self.name = String(rest[rest.index(after: slash)...])
    }

    static func key(game: UUID, name: String) -> String {
        "\(gamePrefix)\(game.uuidString.lowercased())/\(name)"
    }

    static func gamePrefix(_ game: UUID) -> String {
        "\(gamePrefix)\(game.uuidString.lowercased())/"
    }
}
