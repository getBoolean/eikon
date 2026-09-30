import EikonCore
import Foundation
import Testing
@testable import EikonKit

// MARK: Fakes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class CheckedRuntime: GameRuntime {
    static let checks = Counter()
    static var route: RouteID { .nativeRenPy }

    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck {
        checks.increment()
        return .ok
    }

    @MainActor init() {}
    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {}
    @MainActor func pause() {}
    @MainActor func resume() {}
    @MainActor func stop() async {}
}

private final class OtherRuntime: GameRuntime {
    static var route: RouteID { .linuxFEX }

    static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }

    @MainActor init() {}
    @MainActor func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {}
    @MainActor func pause() {}
    @MainActor func resume() {}
    @MainActor func stop() async {}
}

// MARK: Render gate

@Test func renderGateEnterSucceedsWhileOpenAndFailsAfterClose() {
    let gate = RenderGate()
    #expect(gate.enter())
    gate.leave()
    #expect(gate.close())
    #expect(!gate.enter())
    gate.open()
    #expect(gate.enter())
    gate.leave()
}

@Test func renderGateCloseWaitsForInFlightFrameToLeave() {
    let gate = RenderGate()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let returned = Counter(), drained = Counter()
    DispatchQueue.global().async {
        _ = gate.enter()
        entered.signal()
        release.wait()
        gate.leave()
    }
    entered.wait()
    DispatchQueue.global().async {
        if gate.close(timeout: 10) { drained.increment() }
        returned.increment()
        closed.signal()
    }
    usleep(20_000)
    #expect(returned.value == 0)
    release.signal()
    closed.wait()
    #expect(drained.value == 1)
}

@Test func renderGateCloseReturnsFalseWhenFrameNeverLeaves() {
    let gate = RenderGate()
    #expect(gate.enter())
    #expect(!gate.close(timeout: 0.01))
    gate.leave()
}

// MARK: Registry

@Test @MainActor func runtimeChecksAreCachedPerRouteGameAndBuildAndRequeriedAfterRegistration() async {
    let registry = RuntimeRegistry()
    registry.register(CheckedRuntime.self)
    let detection = DetectionResult(engine: .renpy, details: EngineDetails(), gameRoot: "", executables: [:],
                                    keyFile: nil, detectorVersion: GameDetector.version)
    let root = FileManager.default.temporaryDirectory
    let game = GameID.random()
    let first = RuntimeCheckKey(gameID: game, build: Keyed(hex: "01"))

    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root, cacheKey: first)
    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root, cacheKey: first)
    #expect(CheckedRuntime.checks.value == 1)

    _ = await registry.check(route: CheckedRuntime.route, detection: detection, root: root,
                             cacheKey: RuntimeCheckKey(gameID: game, build: Keyed(hex: "02")))
    #expect(CheckedRuntime.checks.value == 2)

    registry.register(OtherRuntime.self)
    _ = await registry.checks(detection: detection, root: root, cacheKey: first)
    #expect(CheckedRuntime.checks.value == 3)
    #expect(registry.builtRoutes == [CheckedRuntime.route, OtherRuntime.route])
}
