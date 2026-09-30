import EikonCore
import Foundation

/// The full identity pass, one location at a time: builds the fingerprint, then matches
/// it against every known game. The viewed location goes first. While suspended (a game
/// session is active) it starts nothing and cancels a build in progress, which restarts
/// later.
public final class FingerprintWorker: @unchecked Sendable {
    private let context: LibraryContext
    private let drives: DriveManager
    private let runner = DispatchQueue(label: "eikon.library.fingerprint")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var queue: [UUID] = []
    private var viewed: UUID?
    private var suspended = false
    private var cancelled: Set<UUID> = []
    private var automatic = false
    private var draining = false
    private var progressHandler: (@Sendable (UUID, Double?) -> Void)?
    private var changeHandler: (@Sendable () -> Void)?
    private var mergeHandler: (@Sendable (GameID, GameID) -> Void)?

    public init(context: LibraryContext, drives: DriveManager) {
        self.context = context
        self.drives = drives
    }

    /// A location's build progress in 0...1, then nil when it ends. Called on the worker's thread.
    public var onProgress: (@Sendable (UUID, Double?) -> Void)? {
        get { lock.withLock { progressHandler } }
        set { lock.withLock { progressHandler = newValue } }
    }

    /// After each location is processed. Called on the worker's thread.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    /// After a silent merge (a provisional game turned out to be a copy of another), so
    /// the merge hooks can run.
    public var onMerge: (@Sendable (GameID, GameID) -> Void)? {
        get { lock.withLock { mergeHandler } }
        set { lock.withLock { mergeHandler = newValue } }
    }

    /// From now on, drains the queue in the background whenever there is work.
    public func start() {
        lock.withLock { automatic = true }
        kick()
    }

    public func enqueue(_ ids: [UUID]) {
        lock.withLock {
            for id in ids where !queue.contains(id) {
                queue.append(id)
                cancelled.remove(id)
            }
        }
        kick()
    }

    /// The location on screen jumps to the front of the queue.
    public func setViewed(_ id: UUID?) {
        lock.withLock { viewed = id }
    }

    /// Drops the locations from the queue and cancels a build in progress on them.
    public func cancel(_ ids: some Sequence<UUID>) {
        lock.withLock {
            let ids = Set(ids)
            queue.removeAll { ids.contains($0) }
            cancelled.formUnion(ids)
        }
    }

    public func suspend() {
        lock.withLock { suspended = true }
    }

    public func resume() {
        lock.withLock { suspended = false }
        kick()
    }

    /// Processes the next queued location on the calling thread. False when suspended or
    /// the queue is empty.
    @discardableResult
    public func processNext() -> Bool {
        let next: UUID? = lock.withLock {
            guard !suspended, !queue.isEmpty else { return nil }
            let at = viewed.flatMap { queue.firstIndex(of: $0) } ?? 0
            return queue.remove(at: at)
        }
        guard let id = next else { return false }
        process(id)
        onProgress?(id, nil)
        onChange?()
        return true
    }

    private func kick() {
        let start = lock.withLock {
            guard automatic, !draining, !suspended, !queue.isEmpty else { return false }
            draining = true
            return true
        }
        guard start else { return }
        runner.async { [self] in
            while processNext() {}
            lock.withLock { draining = false }
            kick()
        }
    }

    private func process(_ id: UUID) {
        let contents = context.index.contents
        guard let location = contents.location(id), let detection = location.detection, location.gameID != nil,
              location.identity != .missing, let drive = contents.drive(location.driveID) else { return }
        // An unavailable drive is scanned, and so queued, again once it is back.
        guard let token = drives.open(drive) else { return }
        defer { token.close() }
        let folder = token.url.appendingPathComponent(location.folderName, isDirectory: true)
        setIdentity(id, .fingerprinting)

        let fingerprint: Fingerprint
        let stamp: String
        do {
            let before = try FingerprintBuilder.contentStamp(detection: detection, folder: folder)
            guard before == location.lastSeen.contentStamp else {
                // Changed since the scan found it settled: a new copy may be under way.
                waitForQuiescence(id, stamp: before)
                return
            }
            let progress = onProgress
            fingerprint = try FingerprintBuilder.build(
                detection: detection, folder: folder, secret: context.secret,
                progress: { progress?(id, $0) },
                isCancelled: { [self] in lock.withLock { suspended || cancelled.contains(id) } })
            stamp = try FingerprintBuilder.contentStamp(detection: detection, folder: folder)
            guard stamp == before else {
                // Changed while hashing: wait for the copy to settle, then build again.
                waitForQuiescence(id, stamp: stamp)
                return
            }
        } catch is CancellationError {
            let requeue = lock.withLock {
                guard !cancelled.contains(id) else { return false }
                queue.insert(id, at: 0)
                return true
            }
            if requeue { setIdentity(id, .pending) }
            return
        } catch {
            setIdentity(id, .failed(.unreadable))
            return
        }
        identify(id, fingerprint: fingerprint, stamp: stamp)
    }

    /// Matches the new fingerprint and applies the result.
    private func identify(_ id: UUID, fingerprint: Fingerprint, stamp: String) {
        let settings = context.settings
        let contents = context.index.contents
        guard let location = contents.location(id), let assigned = location.gameID else { return }
        let catalog = LibraryIdentity.catalog(contents, settings: settings)
        let current = IdentityMatcher.resolve(assigned, links: catalog.links)
        // The first full pass may overturn the quick one, so the location's own id doesn't count yet.
        let firstBuild = location.fingerprint == nil
        let result = IdentityMatcher.match(
            fingerprint: fingerprint, at: LocationKey(driveID: location.driveID, folderName: location.folderName),
            knownLocations: LibraryIdentity.knownLocations(contents, links: catalog.links, excluding: firstBuild ? id : nil),
            games: LibraryIdentity.knownGames(contents, catalog: catalog, excluding: id))

        // Removed, split or merged while the build ran: this result no longer applies.
        guard !lock.withLock({ cancelled.contains(id) }), context.index.contents.location(id)?.gameID == assigned else { return }

        var game = current
        var suggestions: [GameID]?
        switch result {
        case .keep(let kept):
            game = kept
        case .attach(let other, _) where other == current:
            break
        case .attach(let other, let rule):
            // A copy of another game: a provisional game with nothing of its own folds into it.
            let alone = !contents.locations.contains {
                $0.id != id && $0.gameID.map { IdentityMatcher.resolve($0, links: catalog.links) } == current
            }
            if rule == .exact, location.isProvisional, alone, !settings.hasSettings(game: current.uuid),
               settings.fingerprints(game: current.uuid).isEmpty,
               let merged = LibraryIdentity.merge(current, into: other, context: context) {
                game = merged.into
                onMerge?(merged.from, merged.into)
            } else {
                suggestions = [other]
            }
        case .newGame(_, let found):
            suggestions = found
        }

        settings.addFingerprint(fingerprint, game: game.uuid)
        update(id) { location in
            location.gameID = game
            location.isProvisional = false
            location.fingerprint = fingerprint
            location.fingerprintedStamp = stamp
            location.identity = .identified
            if let suggestions {
                location.suggestion = suggestions.filter { $0 != game && !location.dismissedSuggestions.contains($0) }
            }
        }
    }

    private func waitForQuiescence(_ id: UUID, stamp: String) {
        let now = context.now()
        update(id) {
            $0.identity = .waitingForQuiescence
            $0.lastSeen.contentStamp = stamp
            $0.lastSeen.stampSince = now
        }
    }

    private func setIdentity(_ id: UUID, _ identity: IdentityState) {
        update(id) { $0.identity = identity }
    }

    private func update(_ id: UUID, _ body: (inout GameLocation) -> Void) {
        context.index.update { contents in
            if let at = contents.locations.firstIndex(where: { $0.id == id }) {
                body(&contents.locations[at])
            }
        }
    }
}
