import Combine
import EikonCore
import Foundation

/// Supplies what the route picker needs to know about this device for one game. The app
/// implements it from JIT status, gates, built runtimes and cached runtime checks.
@MainActor
public protocol RouteEnvironmentSource: AnyObject {
    func environment(for game: GameID, detection: DetectionResult) async -> RouteEnvironment
}

public struct DriveSummary: Sendable, Equatable, Identifiable {
    public var drive: GameDrive
    public var state: DriveState
    public var freeBytes: Int64?
    public var gameCount: Int
    public var id: UUID { drive.id }

    public init(drive: GameDrive, state: DriveState, freeBytes: Int64?, gameCount: Int) {
        self.drive = drive
        self.state = state
        self.freeBytes = freeBytes
        self.gameCount = gameCount
    }
}

/// A game's overall status, from its locations.
public enum GameStatus: Sendable, Equatable {
    case ready
    case identifying
    case waitingForCopy
    case suggestion
    case driveNotConnected
    case missing
    case fingerprintFailed
}

public struct LibraryGame: Sendable, Equatable, Identifiable {
    /// Resolved through merge links.
    public var id: GameID
    /// On screen only: the `displayName` setting, else the first location's folder name.
    public var displayName: String
    public var locations: [GameLocation]
    public var status: GameStatus
    public var suggestions: [GameID]
    /// From the launch location, else the first detected location.
    public var detection: DetectionResult?
}

public enum LaunchLocation: Sendable, Equatable {
    case ready(GameLocation)
    case driveNotConnected
    case missing
}

/// The library the UI binds to: drives, games grouped by resolved game id, and the
/// entry points behind them. Scans and file work run off the main actor.
@MainActor
public final class LibraryController: ObservableObject {
    @Published public private(set) var drives: [DriveSummary] = []
    @Published public private(set) var games: [LibraryGame] = []
    /// Detected, but without a game id yet (still being copied, or about to be matched).
    @Published public private(set) var settling: [GameLocation] = []
    /// No game found: the "Not recognized" list.
    @Published public private(set) var unrecognized: [GameLocation] = []
    @Published public private(set) var decisions: [GameID: RouteDecision] = [:]
    /// Full-fingerprint progress per location, while it runs.
    @Published public private(set) var fingerprintProgress: [UUID: Double] = [:]
    @Published public private(set) var importProgress: Double?

    public weak var environmentSource: (any RouteEnvironmentSource)?

    public let context: LibraryContext
    public let driveManager: DriveManager
    public let scanner: DriveScanner
    public let worker: FingerprintWorker
    public let importer: ImportCoordinator
    private let settings: SettingsController
    private let hooks: GameDataHooks
    private let freeSpace: @Sendable (URL) -> Int64?
    private let work = DispatchQueue(label: "eikon.library.scan")
    private var freeBytes: [UUID: Int64] = [:]
    private var importCancel: CancelFlag?
    private var routeTask: Task<Void, Never>?
    private var followUpScan: Task<Void, Never>?
    private var suspended = false
    private var subscriptions: Set<AnyCancellable> = []

    public init(index: LibraryIndex, settings: SettingsController, secret: LibrarySecret, access: any FolderAccess,
                builtInRoot: URL, hooks: GameDataHooks, now: @escaping @Sendable () -> Date = { Date() },
                freeSpace: @escaping @Sendable (URL) -> Int64? = FreeSpace.live,
                background: any BackgroundActivity = LiveBackgroundActivity()) {
        context = LibraryContext(index: index, settings: settings.store, secret: secret, now: now)
        driveManager = DriveManager(index: index, access: access, builtInRoot: builtInRoot)
        worker = FingerprintWorker(context: context, drives: driveManager)
        scanner = DriveScanner(context: context, drives: driveManager, worker: worker)
        importer = ImportCoordinator(context: context, drives: driveManager, freeSpace: freeSpace, background: background)
        self.settings = settings
        self.hooks = hooks
        self.freeSpace = freeSpace

        let throttle = ProgressThrottle()
        worker.onProgress = { [weak self] id, progress in
            guard throttle.shouldReport(id, progress) else { return }
            Task { @MainActor in self?.fingerprintProgress[id] = progress }
        }
        worker.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        worker.onMerge = { [weak self] from, into in
            Task { @MainActor in await self?.runMergeHooks(from: from, into: into) }
        }
        settings.changes
            .sink { [weak self] change in
                self?.reload()
                if case .routeOverride = change { self?.invalidateRoutes() }
            }
            .store(in: &subscriptions)
        reload()
    }

    /// Over `Documents/` and `Application Support/Eikon`, with the live folder access.
    public static func live(settings: SettingsController, hooks: GameDataHooks) throws -> LibraryController {
        let support = LibraryPaths.support
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return LibraryController(index: LibraryIndex(directory: support), settings: settings,
                                 secret: try LibrarySecret.loadOrCreate(at: LibraryPaths.librarySecret),
                                 access: LiveFolderAccess.live, builtInRoot: LibraryPaths.documents, hooks: hooks)
    }

    /// Startup, in order: keep game files out of backups, clear interrupted imports, check
    /// drives, scan, and start the fingerprint worker.
    public func start() async {
        var documents = driveManager.builtInRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? documents.setResourceValues(values)
        let importer = importer
        await offMain { importer.cleanStaleStaging() }
        await reevaluateDriveStates()
        worker.start()
        await rescan()
    }

    // MARK: Drives

    public func addDrive(_ url: URL) async -> Result<GameDrive, DriveRefusal> {
        let manager = driveManager
        let result = await offMain { manager.add(url) }
        if case .success = result { await rescan() }
        return result
    }

    public func relinkDrive(_ id: UUID, to url: URL, confirmed: Bool) async -> RelinkOutcome {
        let manager = driveManager
        let outcome = await offMain { manager.relink(id, to: url, confirmed: confirmed) }
        if outcome == .relinked { await rescan() }
        return outcome
    }

    public func removeDrive(_ id: UUID) {
        worker.cancel(context.index.contents.locations.filter { $0.driveID == id }.map(\.id))
        driveManager.remove(id)
        refresh()
    }

    /// Opens every drive to refresh its state and free space.
    public func reevaluateDriveStates() async {
        let manager = driveManager, index = context.index, freeSpace = freeSpace
        freeBytes = await offMain {
            manager.reevaluate()
            var free: [UUID: Int64] = [:]
            for drive in index.contents.drives {
                guard let token = manager.open(drive) else { continue }
                free[drive.id] = freeSpace(token.url)
                token.close()
            }
            return free
        }
        reload()
    }

    /// Scans every available drive. Does nothing while background work is suspended.
    public func rescan() async {
        let scanner = scanner
        await offMain { scanner.scanAll() }
        refresh()
    }

    // MARK: Import

    public func importGame(from source: URL, to driveID: UUID, naming: ImportNaming = .original) async -> ImportOutcome {
        let flag = CancelFlag()
        importCancel = flag
        importProgress = 0
        let outcome = await importer.importGame(from: source, to: driveID, naming: naming, progress: { [weak self] progress in
            Task { @MainActor in if self?.importCancel === flag { self?.importProgress = progress } }
        }, isCancelled: { flag.isSet })
        if importCancel === flag {
            importCancel = nil
            importProgress = nil
        }
        if case .imported = outcome { await rescan() }
        return outcome
    }

    public func cancelImport() {
        importCancel?.set()
    }

    // MARK: Identity

    public func merge(_ game: GameID, into target: GameID) async {
        guard let merged = LibraryIdentity.merge(game, into: target, context: context) else { return }
        refresh()
        await runMergeHooks(from: merged.from, into: merged.into)
    }

    @discardableResult
    public func split(location: UUID) -> GameID? {
        let id = LibraryIdentity.split(location: location, context: context)
        refresh()
        return id
    }

    /// Hides a "same game as…?" suggestion on this location for good.
    public func dismissSuggestion(_ game: GameID, on location: UUID) {
        context.index.update { contents in
            guard let at = contents.locations.firstIndex(where: { $0.id == location }) else { return }
            contents.locations[at].suggestion.removeAll { $0 == game }
            if !contents.locations[at].dismissedSuggestions.contains(game) {
                contents.locations[at].dismissedSuggestions.append(game)
            }
        }
        reload()
    }

    public func retryFingerprint(_ location: UUID) {
        context.index.update { contents in
            guard let at = contents.locations.firstIndex(where: { $0.id == location }) else { return }
            contents.locations[at].identity = .pending
            contents.locations[at].lastSeen.stampSince = nil
        }
        reload()
        Task { await rescan() }
    }

    /// The location on screen gets the fingerprint worker's priority.
    public func setViewedLocation(_ location: UUID?) {
        worker.setViewed(location)
    }

    // MARK: Remove

    /// Deletes the chosen locations' folders (on available drives only), and with
    /// `deleteData` the game's settings and saves on every device. Either way the game's
    /// locations leave the index; folders that remain come back on the next scan.
    public func remove(game: GameID, deleteLocations: Set<UUID>, deleteData: Bool) async {
        let links = context.settings.mergeLinks()
        let contents = context.index.contents
        let mine = contents.locations.filter { $0.gameID.map { IdentityMatcher.resolve($0, links: links) } == game }
        worker.cancel(mine.map(\.id))

        let doomed = mine.filter { deleteLocations.contains($0.id) }
        let manager = driveManager
        await offMain {
            for location in doomed {
                guard let drive = contents.drive(location.driveID), let token = manager.open(drive) else { continue }
                defer { token.close() }
                // Never a folder that is, or holds, another drive's root.
                guard let folder = Self.gameFolder(location.folderName, in: token.url),
                      !manager.roots(excluding: drive.id).contains(where: { DriveManager.overlap($0, folder) }) else { continue }
                try? FileManager.default.removeItem(at: folder)
            }
        }

        if deleteData {
            let aliases = links.keys.filter { IdentityMatcher.resolve($0, links: links) == game }
            for id in [game] + aliases {
                context.settings.removeAll(game: id.uuid)
            }
            for hook in hooks.cleanups {
                await hook.removeData(for: game)
            }
        }
        let ids = Set(mine.map(\.id))
        context.index.update { $0.locations.removeAll { ids.contains($0.id) } }
        refresh()
    }

    /// Drops a missing location from the index. Nothing on disk is touched; the folder, if
    /// it comes back, is found again by the next scan.
    public func forget(location: UUID) {
        let removed = context.index.update { contents -> Bool in
            let before = contents.locations.count
            contents.locations.removeAll { $0.id == location && $0.identity == .missing }
            return contents.locations.count != before
        }
        guard removed else { return }
        worker.cancel([location])
        refresh()
    }

    /// A drive's immediate child with this name, or nil when the name could reach elsewhere.
    nonisolated private static func gameFolder(_ name: String, in root: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Launch

    /// A reachable location, preferring the built-in drive, then the most recently used.
    public func launchLocation(for game: GameID) -> LaunchLocation {
        let contents = context.index.contents
        let links = context.settings.mergeLinks()
        let mine = contents.locations.filter { $0.gameID.map { IdentityMatcher.resolve($0, links: links) } == game }
        let present = mine.filter { $0.identity != .missing }
        let reachable = present.filter { driveManager.state(of: $0.driveID) == .available }
        func isBuiltIn(_ location: GameLocation) -> Bool { contents.drive(location.driveID)?.kind == .builtIn }
        let best = reachable.sorted { a, b in
            if isBuiltIn(a) != isBuiltIn(b) { return isBuiltIn(a) }
            return (a.lastUsedAt ?? .distantPast) > (b.lastUsedAt ?? .distantPast)
        }.first
        if let best { return .ready(best) }
        return present.isEmpty ? .missing : .driveNotConnected
    }

    /// Records a launch, for the next launch-location choice.
    public func noteLaunched(location: UUID) {
        let now = context.now()
        context.index.update { contents in
            if let at = contents.locations.firstIndex(where: { $0.id == location }) {
                contents.locations[at].lastUsedAt = now
            }
        }
    }

    // MARK: Sessions

    /// A game session is starting: scans and fingerprinting pause.
    public func suspendBackgroundWork() {
        suspended = true
        followUpScan?.cancel()
        followUpScan = nil
        scanner.suspend()
        worker.suspend()
    }

    public func resumeBackgroundWork() {
        suspended = false
        scanner.resume()
        worker.resume()
        Task { await rescan() }
    }

    // MARK: Routes

    /// Recomputes every game's route decision. Call when JIT usability, gates, the runtime
    /// registry or cached runtime checks change; overrides are watched here.
    public func invalidateRoutes() {
        routeTask?.cancel()
        let games = games
        routeTask = Task { [weak self] in
            var decisions: [GameID: RouteDecision] = [:]
            for game in games {
                guard let detection = game.detection, let self else { continue }
                let environment = await environmentSource?.environment(for: game.id, detection: detection)
                    ?? RouteEnvironment(jitUsable: false, gates: [:], builtRoutes: [], runtimeChecks: [:])
                decisions[game.id] = RoutePicker.decide(detection: detection, environment: environment,
                                                        override: settings.routeOverride(for: game.id))
            }
            guard !Task.isCancelled else { return }
            self?.decisions = decisions
        }
    }

    // MARK: Publishing

    private func refresh() {
        reload()
        invalidateRoutes()
        scheduleFollowUpScan()
    }

    /// A folder still settling needs another scan once the quiescence interval has passed;
    /// nothing else would come before the next scene activation.
    private func scheduleFollowUpScan() {
        guard !suspended, followUpScan == nil,
              context.index.contents.locations.contains(where: { $0.identity == .waitingForQuiescence }) else { return }
        followUpScan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((DriveScanner.quiescence + 1) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            followUpScan = nil
            await rescan()
        }
    }

    /// Rebuilds the published state from the index, drive states and settings.
    private func reload() {
        let contents = context.index.contents
        let links = context.settings.mergeLinks()
        var grouped: [GameID: [GameLocation]] = [:]
        var settling: [GameLocation] = []
        var unrecognized: [GameLocation] = []
        for location in contents.locations {
            if location.detection == nil {
                if location.identity != .missing { unrecognized.append(location) }
            } else if let game = location.gameID {
                grouped[IdentityMatcher.resolve(game, links: links), default: []].append(location)
            } else if location.identity != .missing {
                settling.append(location)
            }
        }

        let states = Dictionary(contents.drives.map { ($0.id, driveManager.state(of: $0.id)) }, uniquingKeysWith: { first, _ in first })
        games = grouped.map { id, locations in
            let launch = launchLocation(for: id)
            var detection: DetectionResult?
            if case .ready(let location) = launch { detection = location.detection }
            var suggestions: [GameID] = []
            for suggested in locations.flatMap(\.suggestion).map({ IdentityMatcher.resolve($0, links: links) })
            where suggested != id && !suggestions.contains(suggested) {
                suggestions.append(suggested)
            }
            return LibraryGame(
                id: id,
                displayName: settings.displayName(for: id) ?? locations[0].folderName,
                locations: locations,
                status: Self.status(locations, states: states, hasSuggestions: !suggestions.isEmpty),
                suggestions: suggestions,
                detection: detection ?? locations.lazy.compactMap(\.detection).first)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        self.settling = settling
        self.unrecognized = unrecognized
        drives = contents.drives.map { drive in
            DriveSummary(drive: drive, state: states[drive.id] ?? .notConnected, freeBytes: freeBytes[drive.id],
                         gameCount: Set(grouped.filter { $0.value.contains { $0.driveID == drive.id } }.keys).count)
        }
    }

    private static func status(_ locations: [GameLocation], states: [UUID: DriveState], hasSuggestions: Bool) -> GameStatus {
        let present = locations.filter { $0.identity != .missing }
        let reachable = present.filter { states[$0.driveID] == .available }
        if reachable.isEmpty { return present.isEmpty ? .missing : .driveNotConnected }
        var failed = false, waiting = false, identifying = false
        for location in reachable {
            switch location.identity {
            case .failed: failed = true
            case .waitingForQuiescence: waiting = true
            case .pending, .fingerprinting: identifying = true
            case .identified, .missing: break
            }
        }
        if failed { return .fingerprintFailed }
        if waiting { return .waitingForCopy }
        if identifying { return .identifying }
        return hasSuggestions ? .suggestion : .ready
    }

    private func runMergeHooks(from: GameID, into: GameID) async {
        for hook in hooks.merges {
            await hook.mergeData(from: from, into: into)
        }
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            work.async { continuation.resume(returning: body()) }
        }
    }
}

/// A one-way cancel switch, safe from any thread.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Lets a progress value through only when it moved by a percent or ended.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [UUID: Double] = [:]

    func shouldReport(_ id: UUID, _ progress: Double?) -> Bool {
        lock.withLock {
            guard let progress else {
                last[id] = nil
                return true
            }
            if let previous = last[id], progress - previous < 0.01, progress < 1 { return false }
            last[id] = progress
            return true
        }
    }
}

extension LibraryController: SessionBackgroundWork {
    public func suspendForSession() {
        suspendBackgroundWork()
    }

    public func resumeAfterSession() {
        resumeBackgroundWork()
    }
}
