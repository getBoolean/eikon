import Foundation

/// Identity state in memory: what merge and split change. The library applies the same
/// operations to the settings store; tests use it directly.
public struct IdentityLedger<Setting: Sendable & Equatable>: Sendable, Equatable {
    public var fingerprints: [GameID: [Fingerprint]]
    /// Location id → game id.
    public var locations: [UUID: GameID]
    public var settings: [GameID: [String: Setting]]
    /// Merged game → the game it merged into.
    public var links: [GameID: GameID]

    public init(fingerprints: [GameID: [Fingerprint]] = [:], locations: [UUID: GameID] = [:],
                settings: [GameID: [String: Setting]] = [:], links: [GameID: GameID] = [:]) {
        self.fingerprints = fingerprints
        self.locations = locations
        self.settings = settings
        self.links = links
    }

    /// `a` becomes an alias of `b`: B keeps its own settings and gains A's others, A's
    /// fingerprints and locations move to B, with B's own builds kept newest. Both ids
    /// are resolved through earlier merges first.
    public mutating func merge(_ a: GameID, into b: GameID) {
        let source = IdentityMatcher.resolve(a, links: links), target = IdentityMatcher.resolve(b, links: links)
        guard source != target else { return }
        links[source] = target
        settings[target, default: [:]].merge(settings[source] ?? [:]) { own, _ in own }
        var combined: [Fingerprint] = []
        for fingerprint in (fingerprints[source] ?? []) + (fingerprints[target] ?? []) {
            combined = IdentityMatcher.adding(fingerprint, to: combined)
        }
        fingerprints[target] = combined
        fingerprints[source] = []
        for (location, game) in locations where game == source {
            locations[location] = target
        }
    }

    /// Gives `location` a new game holding an independent copy of its old game's settings
    /// and the location's own fingerprint. Returns the new id.
    public mutating func split(location: UUID, fingerprint: Fingerprint, mint: () -> GameID = GameID.random) -> GameID {
        let id = mint()
        if let old = locations[location] {
            settings[id] = settings[old] ?? [:]
            fingerprints[old]?.removeAll { $0.exact == fingerprint.exact }
        }
        fingerprints[id] = [fingerprint]
        locations[location] = id
        return id
    }
}
