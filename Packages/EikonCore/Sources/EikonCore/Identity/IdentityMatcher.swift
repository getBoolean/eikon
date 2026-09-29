import Foundation

/// A game the matcher may attach a new fingerprint to.
public struct KnownGame: Sendable, Equatable {
    public var id: GameID
    /// Oldest to newest, at most `Fingerprint.maxPerGame`.
    public var fingerprints: [Fingerprint]
    /// A present (not missing) location on this device.
    public var hasLiveLocationHere: Bool
    /// `deletedAt` is set: never a candidate.
    public var isDeleted: Bool

    public init(id: GameID, fingerprints: [Fingerprint], hasLiveLocationHere: Bool, isDeleted: Bool = false) {
        self.id = id
        self.fingerprints = fingerprints
        self.hasLiveLocationHere = hasLiveLocationHere
        self.isDeleted = isDeleted
    }
}

/// A game folder's place: its drive and normalized folder name.
public struct LocationKey: Hashable, Sendable {
    public var driveID: UUID
    public private(set) var folderName: String

    public init(driveID: UUID, folderName: String) {
        self.driveID = driveID
        self.folderName = NameNormalizer.normalize(folderName)
    }
}

public enum MatchRule: String, Sendable, Equatable {
    case exact, engineID
}

public enum MatchResult: Sendable, Equatable {
    /// Rule 1: a known location keeps its game, whatever changed inside. Add the fingerprint.
    case keep(GameID)
    /// Rules 2–3: attach to this game and add the fingerprint.
    case attach(GameID, MatchRule)
    /// A new game; `suggestions` are possible same-game matches, possibly none.
    case newGame(GameID, suggestions: [GameID])
}

/// Finds a game folder's identity. Pure: callers apply the result.
public enum IdentityMatcher {
    public static let maxLinkHops = 4

    /// Applies the rules in order: known location, exact, engine id, new game. File names
    /// alone never match or suggest: engine-standard layouts make unrelated games look
    /// alike. Pass ids already resolved through merge links.
    public static func match(fingerprint: Fingerprint, at location: LocationKey,
                             knownLocations: [LocationKey: GameID], games: [KnownGame],
                             mint: () -> GameID = GameID.random) -> MatchResult {
        if let id = knownLocations[location], !games.contains(where: { $0.id == id && $0.isDeleted }) {
            return .keep(id)
        }
        let candidates = games.filter { !$0.isDeleted }
        func comparable(_ game: KnownGame) -> [Fingerprint] {
            game.fingerprints.filter { $0.scheme == fingerprint.scheme }
        }
        func newGame(_ suggestions: [KnownGame]) -> MatchResult {
            .newGame(mint(), suggestions: suggestions.map(\.id).sorted())
        }

        let exact = candidates.filter { comparable($0).contains { $0.exact == fingerprint.exact } }
        if exact.count == 1 { return .attach(exact[0].id, .exact) }
        if exact.count > 1 { return newGame(exact) }

        guard let engineID = fingerprint.engineID else { return newGame([]) }
        let declared = candidates.filter { comparable($0).contains { $0.engineID == engineID } }
        if declared.count == 1, !declared[0].hasLiveLocationHere { return .attach(declared[0].id, .engineID) }
        return newGame(declared)
    }

    /// `list` with `fingerprint` as its newest entry: an equal `exact` moves to newest
    /// instead of repeating, and only the newest `Fingerprint.maxPerGame` stay.
    public static func adding(_ fingerprint: Fingerprint, to list: [Fingerprint]) -> [Fingerprint] {
        let updated = list.filter { $0.exact != fingerprint.exact } + [fingerprint]
        return Array(updated.suffix(Fingerprint.maxPerGame))
    }

    /// Follows merge links (merged game → game it merged into) for at most `maxLinkHops`.
    /// A cycle resolves to its lowest member, so every member resolves alike.
    public static func resolve(_ id: GameID, links: [GameID: GameID]) -> GameID {
        var path = [id]
        for _ in 0..<maxLinkHops {
            guard let next = links[path[path.count - 1]] else { break }
            if let repeated = path.firstIndex(of: next) { return path[repeated...].min()! }
            path.append(next)
        }
        return path[path.count - 1]
    }
}
