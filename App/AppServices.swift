import Combine
import EikonCore
import EikonKit
import UIKit

/// Why the app's data couldn't be opened at launch; a code only.
struct StartupFailure: Error {
    var code: String
    /// The library secret exists but couldn't be read: offered to the user to fix or
    /// start over, never replaced on its own.
    var unreadableSecret: URL?
}

/// The app's long-lived objects, created once at launch in the plan's order.
@MainActor
final class AppServices: ObservableObject {
    /// Files the stores left untouched because they couldn't be read, captured once after
    /// wiring; cleared when the user decides.
    @Published private(set) var pendingUnreadable: [URL] = []
    /// A start over left some files unchanged (they couldn't be set aside).
    @Published private(set) var startOverFailed = false

    let jit: JITController
    let registry: RuntimeRegistry
    let settings: SettingsController
    let gates: GateStore
    let hooks: GameDataHooks
    let library: LibraryController
    let crashHistory: CrashHistory
    let crashes: CrashReportController
    let presenter: SessionPresenter
    private let routeEnvironment: AppRouteEnvironment
    private var subscriptions: Set<AnyCancellable> = []
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// The launch's own activation is covered by `start()`.
    private var skipNextActivation = true

    /// After `JITController.gatherFacts()`: runtimes, then the stores and controllers (the
    /// crash controller consumes the last session's sentinel here, before anything can arm
    /// one), then stale staging cleanup and the first scans.
    static func start(jit: JITController) -> Result<AppServices, StartupFailure> {
        do {
            return .success(try AppServices(jit: jit))
        } catch {
            let secret = LibraryPaths.librarySecret
            let unreadable = (error as? IdentityError) == .secretUnavailable && FileManager.default.fileExists(atPath: secret.path)
            return .failure(StartupFailure(code: "\((error as NSError).domain)#\((error as NSError).code)",
                                           unreadableSecret: unreadable ? secret : nil))
        }
    }

    private init(jit: JITController) throws {
        self.jit = jit

        // 2. Runtimes: none in split 02 (the developer test pattern is not a route).
        registry = RuntimeRegistry()

        // 3. Stores and controllers.
        settings = try SettingsController.live()
        gates = GateStore.live()
        hooks = GameDataHooks()
        library = try LibraryController.live(settings: settings, hooks: hooks)
        let sessions = LibraryPaths.sessions
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        crashHistory = CrashHistory(directory: sessions)
        routeEnvironment = AppRouteEnvironment(jit: jit, gates: gates, registry: registry)
        crashes = CrashReportController(dependencies: Self.crashDependencies(
            sentinel: SessionSentinel(directory: sessions), history: crashHistory, jit: jit, gates: gates,
            settings: settings, library: library))
        presenter = SessionPresenter(library: library, settings: settings)

        routeEnvironment.library = library
        library.environmentSource = routeEnvironment
        observeRouteInputs()

        pendingUnreadable = stores.flatMap(\.unreadableFiles)

        // 4–5. Clean interrupted imports, check drives, start scanning.
        let library = library
        startTask = Task { await library.start() }
    }

    /// Scene became active: re-check drives and rescan, after startup has finished, one
    /// refresh at a time, and not while a game runs (its drive is in use).
    func sceneBecameActive() {
        if skipNextActivation {
            skipNextActivation = false
            return
        }
        guard refreshTask == nil else { return }
        let startTask = startTask, library = library, presenter = presenter
        refreshTask = Task { [weak self] in
            await startTask?.value
            if !presenter.isSessionActive {
                await library.reevaluateDriveStates()
                await library.rescan()
            }
            self?.refreshTask = nil
        }
    }

    /// The user keeps the files as they are (to fix them and relaunch).
    func keepUnreadable() {
        pendingUnreadable = []
        startOverFailed = false
    }

    /// Keeps each unreadable file as a backup and lets its store save a fresh one. Files
    /// that couldn't be set aside are reported again.
    func startOverUnreadable() {
        for store in stores where !store.unreadableFiles.isEmpty {
            store.startOver()
        }
        let remaining = stores.flatMap(\.unreadableFiles)
        pendingUnreadable = remaining
        startOverFailed = !remaining.isEmpty
        library.invalidateRoutes()
    }

    private var stores: [any UnreadableFileReporting] {
        [settings.store, library.context.index, gates, crashHistory]
    }

    /// Route decisions follow JIT, gates and the runtime registry; the library already
    /// watches overrides. The crash banner's offer follows the decisions.
    private func observeRouteInputs() {
        let library = library
        gates.onChange = { Task { @MainActor in library.invalidateRoutes() } }
        jit.$status
            .map(\.usable)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in library.invalidateRoutes() }
            .store(in: &subscriptions)
        registry.$builtRoutes
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in library.invalidateRoutes() }
            .store(in: &subscriptions)
        // Published fires before the value is stored: read the decisions on the next turn.
        let crashes = crashes
        library.$decisions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in crashes.refreshAlternative() }
            .store(in: &subscriptions)
    }

    private static func crashDependencies(sentinel: SessionSentinel, history: CrashHistory, jit: JITController,
                                          gates: GateStore, settings: SettingsController,
                                          library: LibraryController) -> CrashReportController.Dependencies {
        func resolved(_ game: GameID) -> GameID {
            IdentityMatcher.resolve(game, links: settings.store.mergeLinks())
        }
        return CrashReportController.Dependencies(
            sentinel: sentinel, history: history, repository: repositoryURL,
            routeDecision: { library.decisions[resolved($0)] },
            displayName: { game in library.games.first { $0.id == resolved(game) }?.displayName },
            setRouteOverride: { settings.setRouteOverride($1, for: resolved($0)) },
            deviceReport: {
                DeviceReport.make(app: AppInfo.from(.main), installMethod: jit.installMethod, evidence: jit.evidence,
                                  jit: jit.status, system: LiveDeviceSystem.current(), now: Date(), gates: gates.current())
            },
            openURL: { UIApplication.shared.open($0) },
            copyToPasteboard: { try? ReportExport.copy($0) })
    }

    /// `EKRepositoryURL`, or the project's own repository when the key is missing or invalid.
    private static var repositoryURL: URL {
        (Bundle.main.object(forInfoDictionaryKey: "EKRepositoryURL") as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/getBoolean/eikon")!
    }
}

/// What the route picker knows about this device: JIT, gates, built runtimes, and the
/// built runtimes' checks for the game's launch location.
@MainActor
final class AppRouteEnvironment: RouteEnvironmentSource {
    weak var library: LibraryController?
    private let jit: JITController
    private let gates: GateStore
    private let registry: RuntimeRegistry

    init(jit: JITController, gates: GateStore, registry: RuntimeRegistry) {
        self.jit = jit
        self.gates = gates
        self.registry = registry
    }

    func environment(for game: GameID, detection: DetectionResult) async -> RouteEnvironment {
        RouteEnvironment(jitUsable: jit.status.usable, gates: gates.states(), builtRoutes: registry.builtRoutes,
                         runtimeChecks: await runtimeChecks(for: game, detection: detection))
    }

    /// Missing checks mean "ok", so a game without a full fingerprint yet (no build key) or
    /// without a reachable location simply has none.
    private func runtimeChecks(for game: GameID, detection: DetectionResult) async -> [RouteID: RuntimeCheck] {
        guard !registry.builtRoutes.isEmpty, let library, case .ready(let location) = library.launchLocation(for: game),
              let build = location.fingerprint?.exact, let drive = library.context.index.contents.drive(location.driveID),
              let token = library.driveManager.open(drive) else { return [:] }
        defer { token.close() }
        let folder = token.url.appendingPathComponent(location.folderName, isDirectory: true)
        let root = detection.gameRoot.isEmpty ? folder : folder.appendingPathComponent(detection.gameRoot, isDirectory: true)
        return await registry.checks(detection: detection, root: root, cacheKey: RuntimeCheckKey(gameID: game, build: build))
    }
}
