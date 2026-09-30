import EikonCore
import Foundation
import os

/// Background work (drive scans, fingerprinting) that pauses while a game runs.
@MainActor
public protocol SessionBackgroundWork: AnyObject {
    func suspendForSession()
    func resumeAfterSession()
}

/// What a session needs from the rest of the app, as seams.
@MainActor
public struct GameSessionEnvironment {
    public var flushSettings: @MainActor () -> Void
    /// Opens the drive's access for the session and returns its closer.
    public var openAccess: @MainActor () throws -> (@MainActor () -> Void)
    public var backgroundWork: any SessionBackgroundWork
    public var recorder: any SessionRecorder
    public var appBuild: String
    public var now: () -> Date
    public var availableMemoryMB: () -> Int
    /// Runs `work` inside a background task; `work` calls `end` when done.
    public var beginBackgroundTask: @MainActor (_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) -> Void

    public init(flushSettings: @escaping @MainActor () -> Void,
                openAccess: @escaping @MainActor () throws -> (@MainActor () -> Void),
                backgroundWork: any SessionBackgroundWork, recorder: any SessionRecorder,
                appBuild: String = AppInfo.from(.main).build, now: @escaping () -> Date = { Date() },
                availableMemoryMB: @escaping () -> Int = { Int(os_proc_available_memory() / 1_048_576) },
                beginBackgroundTask: @escaping @MainActor (_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) -> Void
                    = GameSessionEnvironment.liveBackgroundTask) {
        self.flushSettings = flushSettings
        self.openAccess = openAccess
        self.backgroundWork = backgroundWork
        self.recorder = recorder
        self.appBuild = appBuild
        self.now = now
        self.availableMemoryMB = availableMemoryMB
        self.beginBackgroundTask = beginBackgroundTask
    }

    public static func liveBackgroundTask(_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) {
        work(LiveBackgroundActivity().begin("eikon.session.background"))
    }
}

/// One game session: the sentinel, the drive access, paused background work and memory
/// samples around one runtime instance. Only one runs at a time.
@MainActor
public final class GameSession {
    public static let memorySampleInterval: TimeInterval = 30
    private static let log = Logger(subsystem: "com.getboolean.eikon", category: "session")

    public let game: LaunchableGame
    public private(set) var runtime: (any GameRuntime)?
    /// Set as soon as an end begins; teardown may still be running.
    public private(set) var hasEnded = false
    /// The runtime reported its own end: it gets no more pause, resume or stop calls.
    public private(set) var runtimeEnded = false
    private let runtimeType: any GameRuntime.Type
    private let sentinelRoute: String
    private let environment: GameSessionEnvironment
    private var started = false
    private var closeAccess: (@MainActor () -> Void)?
    private var armed = false
    private var suspendedWork = false
    private var launch: Task<Void, any Error>?
    private var teardown: Task<Void, Never>?
    private var memoryTimer: Timer?
    private var samplesPaused = false

    /// `sentinelRoute` defaults to the game's route; test sessions pass `SessionRecord.testRoute`.
    public init(game: LaunchableGame, runtimeType: any GameRuntime.Type, sentinelRoute: String? = nil,
                environment: GameSessionEnvironment) {
        self.game = game
        self.runtimeType = runtimeType
        self.sentinelRoute = sentinelRoute ?? game.route.rawValue
        self.environment = environment
    }

    /// Whether the runtime may still be paused or resumed.
    var isLive: Bool { !hasEnded && !runtimeEnded }

    /// Flush settings, open the drive, arm the sentinel, pause background work, then
    /// launch. A failure unwinds what was done and is rethrown. Runs once.
    func start(host: any GameSessionHost) async throws {
        precondition(!started, "a GameSession starts once")
        started = true
        environment.flushSettings()
        do {
            closeAccess = try environment.openAccess()
            try environment.recorder.arm(SessionRecord(
                gameID: game.gameID, engine: game.detection.engine,
                architecture: Self.architecture(game.detection, route: game.route),
                route: sentinelRoute, appBuild: environment.appBuild, startedAt: environment.now()))
            armed = true
            add(.sessionStart)
            environment.backgroundWork.suspendForSession()
            suspendedWork = true

            let runtime = runtimeType.init()
            self.runtime = runtime
            host.renderGate.open()
            startMemorySamples()
            let game = game
            let launch = Task { try await runtime.launch(game, in: host) }
            self.launch = launch
            do {
                try await launch.value
            } catch {
                add(.runtimeError(code: Int64((error as NSError).code)))
                throw error
            }
        } catch {
            await end(runtimeReportedEnd: false)
            throw error
        }
    }

    /// Marks the runtime's own end at once, before the teardown gets to run.
    func markRuntimeEnded() {
        runtimeEnded = true
    }

    /// Quit, the runtime's own end and a failed launch all come here. Every caller waits
    /// for the one teardown, which never stops the runtime while its launch is running.
    func end(runtimeReportedEnd: Bool) async {
        if runtimeReportedEnd { runtimeEnded = true }
        if let teardown { return await teardown.value }
        hasEnded = true
        let teardown = Task { await tearDown() }
        self.teardown = teardown
        await teardown.value
    }

    private func tearDown() async {
        _ = await launch?.result
        if let runtime, !runtimeEnded {
            await runtime.stop()
        }
        // The runtime may hold the host; the host holds this session.
        runtime = nil
        if armed {
            environment.recorder.add(.sessionStop)
            environment.recorder.disarm()
        }
        closeAccess?()
        closeAccess = nil
        if suspendedWork {
            environment.backgroundWork.resumeAfterSession()
        }
        memoryTimer?.invalidate()
        memoryTimer = nil
    }

    func add(_ event: BreadcrumbEvent) {
        guard armed, !hasEnded else { return }
        environment.recorder.add(event)
    }

    func setPhase(_ phase: SessionRecord.Phase) {
        guard armed, !hasEnded else { return }
        do {
            try environment.recorder.setPhase(phase)
        } catch {
            // The sentinel vanished: a crash now would go unreported. Codes only.
            Self.log.error("sentinel phase write failed: \((error as NSError).code, privacy: .public)")
            assertionFailure("sentinel phase write failed")
        }
    }

    func flushSettings() {
        environment.flushSettings()
    }

    func inBackgroundTask(_ work: @escaping @MainActor (_ end: @escaping @MainActor () -> Void) -> Void) {
        environment.beginBackgroundTask(work)
    }

    func recordMemorySample() {
        add(.memorySample(availableMB: Int64(environment.availableMemoryMB())))
    }

    /// Samples run only while the game runs.
    func setSamplesPaused(_ paused: Bool) {
        samplesPaused = paused
    }

    private func startMemorySamples() {
        let timer = Timer(timeInterval: Self.memorySampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.samplesPaused else { return }
                self.recordMemorySample()
            }
        }
        // Common modes, so samples continue while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        memoryTimer = timer
    }

    /// The main executable's architecture for the route's platform.
    static func architecture(_ detection: DetectionResult, route: RouteID) -> CPUArchitecture? {
        switch route {
        case .wineFEX, .wineBox64, .nativeKirikiri, .nativeRenPy: detection.executables[.windows]?.architecture
        case .linuxFEX: detection.executables[.linux]?.architecture
        }
    }
}
