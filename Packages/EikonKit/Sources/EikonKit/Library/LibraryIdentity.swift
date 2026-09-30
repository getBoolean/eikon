import EikonCore
import Foundation

/// What the library parts share.
public struct LibraryContext: Sendable {
    public let index: LibraryIndex
    public let settings: SettingsStore
    public let secret: LibrarySecret
    public let now: @Sendable () -> Date

    public init(index: LibraryIndex, settings: SettingsStore, secret: LibrarySecret,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.index = index
        self.settings = settings
        self.secret = secret
        self.now = now
    }
}

/// Matcher inputs and the merge and split operations over the index and settings store.
enum LibraryIdentity {
    /// Every location's resolved game, keyed by drive and normalized folder name.
    static func knownLocations(_ contents: LibraryContents, links: [GameID: GameID],
                               excluding excluded: UUID? = nil) -> [LocationKey: GameID] {
        var known: [LocationKey: GameID] = [:]
        for location in contents.locations where location.id != excluded {
            guard let game = location.gameID else { continue }
            known[LocationKey(driveID: location.driveID, folderName: location.folderName)] = IdentityMatcher.resolve(game, links: links)
        }
        return known
    }

    /// What the settings store knows about every resolved game: read once, outside the
    /// index lock, since it walks the whole store.
    struct Catalog {
        var links: [GameID: GameID]
        var fingerprints: [GameID: [Fingerprint]]
        var deleted: Set<GameID>
    }

    static func catalog(_ contents: LibraryContents, settings: SettingsStore) -> Catalog {
        let links = settings.mergeLinks()
        let ids = Set((settings.knownGames().map(GameID.init) + contents.locations.compactMap(\.gameID))
            .map { IdentityMatcher.resolve($0, links: links) })
        var catalog = Catalog(links: links, fingerprints: [:], deleted: [])
        for id in ids {
            if settings.isDeleted(game: id.uuid) {
                catalog.deleted.insert(id)
            } else {
                catalog.fingerprints[id] = settings.fingerprints(game: id.uuid)
            }
        }
        return catalog
    }

    /// Every cataloged game. Deleted ones are passed as deleted, so the matcher never keeps
    /// or attaches to them.
    static func knownGames(_ contents: LibraryContents, catalog: Catalog, excluding excluded: UUID) -> [KnownGame] {
        let games = catalog.fingerprints.map { id, fingerprints in
            KnownGame(id: id, fingerprints: fingerprints, hasLiveLocationHere: contents.locations.contains { location in
                location.id != excluded && location.identity != .missing
                    && location.gameID.map { IdentityMatcher.resolve($0, links: catalog.links) } == id
            })
        }
        let deleted = catalog.deleted.map { KnownGame(id: $0, fingerprints: [], hasLiveLocationHere: false, isDeleted: true) }
        return (games + deleted).sorted { $0.id < $1.id }
    }

    /// `a` becomes an alias of `b`: B keeps its own settings and gains A's others, A's
    /// fingerprints and locations move to B. Returns the resolved pair, or nil when they
    /// are already one game.
    @discardableResult
    static func merge(_ a: GameID, into b: GameID, context: LibraryContext) -> (from: GameID, into: GameID)? {
        let settings = context.settings
        let links = settings.mergeLinks()
        let source = IdentityMatcher.resolve(a, links: links), target = IdentityMatcher.resolve(b, links: links)
        guard source != target else { return nil }
        settings.set(.merged(source.uuid), target.uuid.uuidString.lowercased())
        settings.copySettings(from: source.uuid, to: target.uuid, onlyWhereUnset: true)
        let moved = settings.fingerprints(game: source.uuid)
        // Re-adding B's own afterwards keeps them newest, as `IdentityLedger.merge` does.
        for fingerprint in moved + settings.fingerprints(game: target.uuid) {
            settings.addFingerprint(fingerprint, game: target.uuid)
        }
        for fingerprint in moved {
            settings.removeFingerprint(fingerprint, game: source.uuid)
        }
        context.index.update { contents in
            for at in contents.locations.indices {
                var location = contents.locations[at]
                var game = location.gameID.map { IdentityMatcher.resolve($0, links: links) }
                if game == source {
                    location.gameID = target
                    location.isProvisional = false
                    game = target
                }
                var suggestions: [GameID] = []
                for suggested in location.suggestion.map({ $0 == source ? target : $0 })
                where suggested != game && !suggestions.contains(suggested) {
                    suggestions.append(suggested)
                }
                location.suggestion = suggestions
                contents.locations[at] = location
            }
        }
        return (source, target)
    }

    /// Gives the location a new game with a copy of its old game's settings and the
    /// location's own fingerprint. Returns the new id.
    static func split(location id: UUID, context: LibraryContext) -> GameID? {
        let settings = context.settings
        guard let location = context.index.contents.location(id), let old = location.gameID else { return nil }
        let oldGame = IdentityMatcher.resolve(old, links: settings.mergeLinks())
        let new = GameID.random()
        settings.copySettings(from: oldGame.uuid, to: new.uuid, onlyWhereUnset: false)
        if let fingerprint = location.fingerprint {
            settings.removeFingerprint(fingerprint, game: oldGame.uuid)
            settings.addFingerprint(fingerprint, game: new.uuid)
        }
        context.index.update { contents in
            if let at = contents.locations.firstIndex(where: { $0.id == id }) {
                contents.locations[at].gameID = new
                contents.locations[at].isProvisional = false
                contents.locations[at].suggestion = []
            }
        }
        return new
    }
}
