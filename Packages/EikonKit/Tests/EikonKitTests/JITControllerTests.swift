import Foundation
import Testing
@testable import EikonKit

/// Settable CS_DEBUGGED, a fixed absent TXM, and a probe that always passes.
final class FakeJITSystem: JITSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var debugged = false
    private var probes = 0

    var csDebuggedFlag: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return debugged
        }
        set {
            lock.lock()
            debugged = newValue
            lock.unlock()
        }
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    func csDebugged() -> Bool { csDebuggedFlag }

    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo {
        TXMInfo(state: .absent, enforced: false, basis: "test")
    }

    func probe() -> ProbeOutcome {
        lock.lock()
        probes += 1
        lock.unlock()
        return ProbeOutcome(kind: .passed, detail: nil)
    }
}

@MainActor
final class URLRecorder {
    private(set) var opened: [URL] = []
    var result = true
    var onOpen: (() -> Void)?

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        onOpen?()
        return result
    }
}

final class FakeClock: JITClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(seconds: Double) async throws {
        advance(by: seconds)
        await Task.yield()
    }

    private func advance(by seconds: Double) {
        lock.lock()
        current.addTimeInterval(seconds)
        lock.unlock()
    }
}

@MainActor
private struct ControllerHarness {
    let system = FakeJITSystem()
    let recorder = URLRecorder()
    let clock: FakeClock
    let defaults: UserDefaults
    let suiteName: String
    let sentinelDirectory: URL
    let store = JITStatusStore()
    let controller: JITController
    let bundleID = "com.example.sideload.rewritten"

    init() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        clock = FakeClock(start: start)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        sentinelDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jit-controller-\(UUID().uuidString)", isDirectory: true)

        let bundleURL = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/EIKONTEST/Eikon.app")
        let environment = FakeBundleEnvironment(
            bundleURL: bundleURL,
            homeDirectory: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/EIKONDATA"),
            bundleIdentifier: bundleID,
            entitlements: ["com.apple.private.security.container-required": bundleID]
        )
        let sentinel = ProbeSentinel(directory: sentinelDirectory, buildNumber: "1")
        let system = system
        let recorder = recorder
        controller = JITController(
            environment: environment,
            system: system,
            defaults: defaults,
            openURL: { url in await recorder.open(url) },
            clock: clock,
            bundleIdentifier: bundleID,
            sentinel: sentinel,
            store: store
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: sentinelDirectory)
    }
}

@Test @MainActor func oneRequestNoBounce() async {
    let harness = ControllerHarness()
    defer { harness.cleanup() }

    harness.controller.gatherFacts()
    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()

    #expect(harness.recorder.opened.count == 1)
    #expect(harness.recorder.opened.first?.absoluteString.contains(harness.bundleID) == true)

    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()
    #expect(harness.recorder.opened.count == 1)
}

@Test @MainActor func jitArrivesFromTrollStore() async {
    let harness = ControllerHarness()
    defer { harness.cleanup() }
    harness.recorder.onOpen = { harness.system.csDebuggedFlag = true }

    harness.controller.gatherFacts()
    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()

    #expect(harness.controller.status.usable)
    #expect(harness.controller.status.source == .trollStore)
    #expect(!harness.controller.isRequestingTrollStoreJIT)
}

@Test @MainActor func deadlineWithoutReactivation() async {
    let harness = ControllerHarness()
    defer { harness.cleanup() }

    harness.controller.gatherFacts()
    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()

    #expect(!harness.controller.status.usable)
    #expect(harness.controller.status.reason == .trollStoreTimedOut)
    #expect(!harness.controller.isRequestingTrollStoreJIT)
}

@Test @MainActor func openFailsWithoutWaiting() async {
    let harness = ControllerHarness()
    defer { harness.cleanup() }
    harness.recorder.result = false
    let start = harness.clock.now()

    harness.controller.gatherFacts()
    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()

    #expect(harness.controller.status.reason == .trollStoreTimedOut)
    #expect(!harness.controller.isRequestingTrollStoreJIT)
    #expect(harness.clock.now() == start)
}

@Test @MainActor func storeMirrorsController() async {
    let harness = ControllerHarness()
    defer { harness.cleanup() }

    harness.controller.gatherFacts()
    #expect(harness.store.current == harness.controller.status)

    harness.recorder.onOpen = { harness.system.csDebuggedFlag = true }
    harness.controller.sceneBecameActive()
    await harness.controller.waitForPendingRequest()

    #expect(harness.store.current == harness.controller.status)
    #expect(harness.controller.status.usable)
}
