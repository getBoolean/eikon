import CryptoKit
import EikonCore
import Foundation

/// Diffs each available drive's game folders against its locations: new folders become
/// locations, vanished ones go missing (never deleted), changed ones are re-detected.
/// Once a folder's content stamp holds still for `quiescence`, it gets a game id at once
/// (the quick pass) and joins the fingerprint worker's queue (the full pass).
public final class DriveScanner: @unchecked Sendable {
    /// How long a content stamp must hold before matching starts.
    public static let quiescence: TimeInterval = 10

    private let context: LibraryContext
    private let drives: DriveManager
    private let worker: FingerprintWorker
    private let lock = NSLock()
    private var suspended = false

    public init(context: LibraryContext, drives: DriveManager, worker: FingerprintWorker) {
        self.context = context
        self.drives = drives
        self.worker = worker
    }

    /// While suspended (a game session is active), scans do nothing.
    public func suspend() {
        lock.withLock { suspended = true }
    }

    public func resume() {
        lock.withLock { suspended = false }
    }

    /// Scans every available drive. Blocking: call it off the main actor.
    public func scanAll() {
        for drive in context.index.contents.drives {
            scan(drive)
        }
    }

    public func scan(_ drive: GameDrive) {
        guard !lock.withLock({ suspended }), let token = drives.open(drive) else { return }
        defer { token.close() }
        guard let folders = try? Self.gameFolders(in: token.url, builtIn: drive.kind == .builtIn) else { return }

        let snapshot = context.index.contents
        let now = context.now()
        var observations: [Observation] = []
        for folder in folders {
            // A session started: drop the scan rather than keep walking game trees.
            if lock.withLock({ suspended }) { return }
            observations.append(observe(folder, existing: snapshot.locations.first {
                $0.driveID == drive.id && $0.folderName == folder.lastPathComponent
            }, now: now))
        }
        let catalog = LibraryIdentity.catalog(snapshot, settings: context.settings)

        let settled = context.index.update { contents -> [UUID] in
            let present = Set(folders.map(\.lastPathComponent))
            // Missing first, so a renamed or moved game's old location no longer counts as live.
            for at in contents.locations.indices
            where contents.locations[at].driveID == drive.id && !present.contains(contents.locations[at].folderName) {
                contents.locations[at].identity = .missing
            }
            var settled: [UUID] = []
            for observation in observations {
                let at: Int
                if let found = contents.locations.firstIndex(where: { $0.driveID == drive.id && $0.folderName == observation.name }) {
                    at = found
                } else {
                    contents.locations.append(GameLocation(driveID: drive.id, folderName: observation.name))
                    at = contents.locations.count - 1
                }
                if apply(observation, at: at, to: &contents, catalog: catalog, now: now) {
                    settled.append(contents.locations[at].id)
                }
            }
            return settled
        }
        worker.enqueue(settled)
    }

    /// A drive's game folders: immediate subfolders, minus dot folders (including import
    /// staging) and, on the built-in drive, `Inbox`. Symlinks are not folders here.
    static func gameFolders(in root: URL, builtIn: Bool) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { url in
                let name = url.lastPathComponent
                guard !name.hasPrefix("."), !(builtIn && name == "Inbox") else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Observing (file I/O, outside the index lock)

    private struct Observation {
        var name: String
        var modifiedAt: Date?
        var listingDigest: String?
        /// Set when detection ran this scan; `.some(nil)` means no game was found.
        var detection: DetectionResult??
        /// nil without a detection; `.failure` when the tree couldn't be read.
        var stamp: Result<String, any Error>?
        var engineID: Keyed?
    }

    private func observe(_ folder: URL, existing: GameLocation?, now: Date) -> Observation {
        var observation = Observation(name: folder.lastPathComponent)
        observation.modifiedAt = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        observation.listingDigest = Self.listingDigest(folder)

        var detection = existing?.detection
        func detect() {
            // A read error (a USB hiccup) keeps the cached detection; only a clean nil means no game.
            do {
                let found = try GameDetector.detect(folder: folder)
                detection = found
                observation.detection = .some(found)
            } catch {}
        }
        func stamp() -> Result<String, any Error>? {
            detection.map { detection in Result { try FingerprintBuilder.contentStamp(detection: detection, folder: folder) } }
        }

        let seen = existing?.lastSeen
        if existing == nil || detection == nil || detection?.engine == .unknown
            || (detection?.detectorVersion ?? 0) < GameDetector.version
            || observation.modifiedAt != seen?.modifiedAt || observation.listingDigest != seen?.listingDigest {
            detect()
        }
        observation.stamp = stamp()
        if observation.detection == nil, case .success(let current)? = observation.stamp, current != seen?.contentStamp {
            // Contents changed below the top level: detection is a cache of them.
            detect()
            observation.stamp = stamp()
        }

        // Read the engine id only when the quick pass will run on this scan.
        if let existing, existing.gameID == nil, let detection, case .success(let current)? = observation.stamp,
           current == seen?.contentStamp, let since = seen?.stampSince, now.timeIntervalSince(since) >= Self.quiescence {
            observation.engineID = try? FingerprintBuilder.engineID(detection: detection, folder: folder, secret: context.secret)
        }
        return observation
    }

    private static func listingDigest(_ folder: URL) -> String? {
        guard let listing = try? FolderListing(url: folder) else { return nil }
        var bytes = Data()
        for entry in listing.entries.sorted(by: { $0.name < $1.name }) {
            bytes.append(contentsOf: Data("\(entry.kind.rawValue):\(entry.name)\u{0}".utf8))
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Applying (under the index lock)

    /// Updates the location; true when it is settled and needs the full pass.
    private func apply(_ observation: Observation, at position: Int, to contents: inout LibraryContents,
                       catalog: LibraryIdentity.Catalog, now: Date) -> Bool {
        var location = contents.locations[position]
        defer { contents.locations[position] = location }
        location.lastSeen.modifiedAt = observation.modifiedAt
        location.lastSeen.listingDigest = observation.listingDigest
        if let detection = observation.detection {
            location.detection = detection
        }
        // The worker owns a build in progress; it checks the stamp itself when done.
        if location.identity == .fingerprinting { return false }
        if location.identity == .missing {
            location.identity = .pending
        }
        guard location.detection != nil, let stampResult = observation.stamp else {
            location.identity = .pending
            return false
        }
        guard case .success(let stamp) = stampResult else {
            location.identity = .failed(.unreadable)
            return false
        }

        let changed = stamp != location.lastSeen.contentStamp || location.lastSeen.stampSince == nil
        if changed {
            location.lastSeen.contentStamp = stamp
            location.lastSeen.stampSince = now
        }
        if stamp == location.fingerprintedStamp {
            location.identity = .identified
            return false
        }
        if case .failed = location.identity, !changed { return false }
        guard let since = location.lastSeen.stampSince, now.timeIntervalSince(since) >= Self.quiescence else {
            location.identity = .waitingForQuiescence
            return false
        }

        if location.gameID == nil {
            let result = IdentityMatcher.quickMatch(
                engineID: observation.engineID, at: LocationKey(driveID: location.driveID, folderName: location.folderName),
                knownLocations: LibraryIdentity.knownLocations(contents, links: catalog.links, excluding: location.id),
                games: LibraryIdentity.knownGames(contents, catalog: catalog, excluding: location.id))
            switch result {
            case .keep(let game), .attach(let game, _):
                location.gameID = game
            case .newGame(let game, let suggestions):
                location.gameID = game
                location.isProvisional = true
                location.suggestion = suggestions.filter { !location.dismissedSuggestions.contains($0) }
            }
        }
        location.identity = .pending
        return true
    }
}
