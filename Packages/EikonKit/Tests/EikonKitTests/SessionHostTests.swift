import EikonCore
import Foundation
import Testing
import UIKit
@testable import EikonKit

// MARK: Fakes

/// One ordered log shared by the runtime, recorder and environment of a test.
@MainActor
private final class Log {
    private(set) var entries: [String] = []

    func add(_ entry: String) {
        entries.append(entry)
    }

    func count(_ entry: String) -> Int {
        entries.filter { $0 == entry }.count
    }

    func index(_ entry: String) -> Int? {
        entries.firstIndex(of: entry)
    }
}

private final class FakeRuntime: GameRuntime {
    /// The runtime is created inside the session's start, so it picks up the test's log.
    @TaskLocal static var currentLog: Log?

    static var route: RouteID { .nativeRenPy }
    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }

    private let log: Log?

    @MainActor init() {
        log = Self.currentLog
    }

    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws { log?.add("launch") }
    @MainActor func pause() { log?.add("pause") }
    @MainActor func resume() { log?.add("resume") }
    @MainActor func stop() async { log?.add("stop") }
}

@MainActor
private final class FakeRecorder: SessionRecorder {
    let log: Log

    init(_ log: Log) {
        self.log = log
    }

    func arm(_ record: SessionRecord) throws { log.add("arm") }
    func setPhase(_ phase: SessionRecord.Phase) throws { log.add("phase:\(phase.rawValue)") }
    func add(_ event: BreadcrumbEvent) { log.add("crumb:\(event)") }
    func disarm() { log.add("disarm") }
}

@MainActor
private final class FakeBackgroundWork: SessionBackgroundWork {
    let log: Log

    init(_ log: Log) {
        self.log = log
    }

    func suspendForSession() { log.add("suspendWork") }
    func resumeAfterSession() { log.add("resumeWork") }
}

@MainActor
private final class FakeSceneEvents: SceneEvents {
    func subscribe(_ handler: @escaping @MainActor (SceneEvent) -> Void) -> SceneEventsSubscription {
        SceneEventsSubscription {}
    }
}

@MainActor
private func startedHost(_ log: Log) async throws -> GameSessionHostViewController {
    let environment = GameSessionEnvironment(
        flushSettings: { log.add("flush") },
        openAccess: {
            log.add("open")
            return { log.add("close") }
        },
        backgroundWork: FakeBackgroundWork(log), recorder: FakeRecorder(log), appBuild: "1",
        availableMemoryMB: { 100 },
        beginBackgroundTask: { work in work {} })
    let detection = DetectionResult(engine: .renpy, details: EngineDetails(), gameRoot: "", executables: [:],
                                    keyFile: nil, detectorVersion: GameDetector.version)
    let game = LaunchableGame(gameID: .random(), root: FileManager.default.temporaryDirectory, detection: detection,
                              route: FakeRuntime.route)
    let host = GameSessionHostViewController(session: GameSession(game: game, runtimeType: FakeRuntime.self,
                                                                  environment: environment),
                                             events: FakeSceneEvents())
    try await FakeRuntime.$currentLog.withValue(log) {
        try await host.start()
    }
    return host
}

// MARK: Lifecycle

@Test @MainActor func willDeactivateClosesGateAndPausesRuntime() async throws {
    let log = Log()
    let host = try await startedHost(log)
    #expect(host.renderGate.enter())
    host.renderGate.leave()

    host.handle(.willDeactivate)
    #expect(log.count("pause") == 1)
    #expect(!host.renderGate.enter())
}

@Test @MainActor func phaseBecomesBackgroundOnlyOnDidEnterBackgroundAfterGateClosed() async throws {
    let log = Log()
    let host = try await startedHost(log)
    host.handle(.willDeactivate)
    #expect(log.index("phase:background") == nil)

    host.handle(.didEnterBackground)
    let pause = try #require(log.index("pause")), background = try #require(log.index("phase:background"))
    #expect(pause < background)
    #expect(!host.renderGate.enter())
}

@Test @MainActor func didActivateSetsRunningButWaitsForOverlayResume() async throws {
    let log = Log()
    let host = try await startedHost(log)
    host.handle(.willDeactivate)
    host.handle(.didEnterBackground)
    host.handle(.didActivate)
    #expect(log.entries.last { $0.hasPrefix("phase:") } == "phase:running")
    #expect(log.count("resume") == 0)
    #expect(host.isResumeOverlayVisible)
    #expect(!host.renderGate.enter())

    host.resumeSession()
    #expect(host.renderGate.enter())
    host.renderGate.leave()
    #expect(log.count("resume") == 1)
    #expect(!host.isResumeOverlayVisible)
}

@Test @MainActor func audioInterruptionPausesAndItsEndDoesNotAutoResume() async throws {
    let log = Log()
    let host = try await startedHost(log)
    host.handle(.audioInterruptionBegan)
    #expect(log.count("pause") == 1)

    host.handle(.audioInterruptionEnded)
    #expect(log.count("resume") == 0)
    #expect(host.isResumeOverlayVisible)
}

@Test @MainActor func quitStopsRuntimeDisarmsSentinelAndClosesAccessToken() async throws {
    let log = Log()
    let host = try await startedHost(log)
    await host.quit()

    let stop = try #require(log.index("stop")), disarm = try #require(log.index("disarm")),
        close = try #require(log.index("close"))
    #expect(stop < disarm)
    #expect(disarm < close)
    #expect(log.count("resumeWork") == 1)
}

// MARK: Presentation

@MainActor
private final class StubController: UIViewController {
    var stubPresented: UIViewController?
    var presentedHere: UIViewController?

    override var presentedViewController: UIViewController? { stubPresented }

    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        presentedHere = controller
        completion?()
    }
}

@Test @MainActor func presenterUsesTopmostPresentedController() async throws {
    let root = StubController(), first = StubController(), second = StubController()
    root.stubPresented = first
    first.stubPresented = second
    #expect(SessionPresentation.topmostPresented(from: root) === second)

    let host = try await startedHost(Log())
    await SessionPresentation.present(host, from: root, animated: false)
    #expect(second.presentedHere === host)
    #expect(root.presentedHere == nil)
}

// MARK: Recorder

@Test @MainActor func liveRecorderKeepsBreadcrumbsWrittenAfterArming() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = LiveSessionRecorder(directory: directory)
    try recorder.arm(SessionRecord(gameID: .random(), engine: .renpy, architecture: nil, route: SessionRecord.testRoute,
                                   appBuild: "1", startedAt: Date()))
    recorder.add(.memoryWarning)

    let consumed = SessionSentinel(directory: directory).consumeAtLaunch()
    recorder.disarm()
    #expect(consumed?.breadcrumbs.contains { $0.event == .memoryWarning } == true)
}
