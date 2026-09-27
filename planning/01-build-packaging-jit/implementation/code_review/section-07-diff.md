diff --git a/App/EikonApp.swift b/App/EikonApp.swift
index 0566bde..3a89252 100644
--- a/App/EikonApp.swift
+++ b/App/EikonApp.swift
@@ -1,10 +1,24 @@
+import EikonKit
 import SwiftUI
 
 @main
 struct EikonApp: App {
+    @ObservedObject private var jit = JITController.shared
+    @Environment(\.scenePhase) private var scenePhase
+
+    init() {
+        JITController.shared.gatherFacts()
+    }
+
     var body: some Scene {
         WindowGroup {
             StatusView()
+                .environmentObject(jit)
+                .onChange(of: scenePhase) { phase in
+                    if phase == .active {
+                        jit.sceneBecameActive()
+                    }
+                }
         }
     }
 }
diff --git a/Packages/EikonKit/Sources/EikonKit/JITClock.swift b/Packages/EikonKit/Sources/EikonKit/JITClock.swift
new file mode 100644
index 0000000..f099741
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/JITClock.swift
@@ -0,0 +1,18 @@
+import Foundation
+
+/// Minimal time seam. Swift's Clock protocol needs iOS 16.
+public protocol JITClock: Sendable {
+    func now() -> Date
+    func sleep(seconds: Double) async throws
+}
+
+public struct LiveJITClock: JITClock {
+    public init() {}
+
+    public func now() -> Date { Date() }
+
+    public func sleep(seconds: Double) async throws {
+        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
+        try await Task.sleep(nanoseconds: nanoseconds)
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/JITController.swift b/Packages/EikonKit/Sources/EikonKit/JITController.swift
new file mode 100644
index 0000000..118a02f
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/JITController.swift
@@ -0,0 +1,275 @@
+#if canImport(UIKit)
+import UIKit
+#endif
+import Combine
+import Foundation
+
+/// Owns JIT state for the process: gathers facts, asks TrollStore once, and
+/// republishes whenever usability can change.
+@MainActor
+public final class JITController: ObservableObject {
+    public static let shared = JITController(
+        environment: .live,
+        system: .live,
+        defaults: .standard,
+        openURL: { url in
+            #if canImport(UIKit)
+            await UIApplication.shared.open(url)
+            #else
+            false
+            #endif
+        },
+        clock: LiveJITClock(),
+        bundleIdentifier: Bundle.main.bundleIdentifier,
+        sentinel: ProbeSentinel.live(buildNumber: SystemInfo.buildNumber),
+        store: .shared
+    )
+
+    @Published public private(set) var status: JITStatus
+    @Published public private(set) var installMethod: InstallMethod
+    @Published public private(set) var evidence: InstallEvidence
+    @Published public private(set) var isRequestingTrollStoreJIT: Bool
+
+    private let environment: any BundleEnvironment
+    private let system: any JITSystem
+    private let defaults: UserDefaults
+    private let openURL: @MainActor (URL) async -> Bool
+    private let clock: any JITClock
+    private let bundleIdentifier: String?
+    private let sentinel: ProbeSentinel
+    private let store: JITStatusStore
+
+    private var facts: JITFacts
+    private var lastProbe: ProbeOutcome
+    private var hasActivated = false
+    private var triedTrollStoreThisProcess = false
+    private var requestTask: Task<Void, Never>?
+
+    private static let lastAttemptKey = "eikon.lastTrollStoreJITAttempt"
+    /// How long to wait for TrollStore to set CS_DEBUGGED.
+    private static let requestDeadline: TimeInterval = 10
+    /// How often to re-read CS_DEBUGGED during a request.
+    private static let pollInterval: TimeInterval = 0.2
+    /// Pause after CS_DEBUGGED appears, so TrollStore's tracer has detached before the probe.
+    private static let gracePeriod: TimeInterval = 0.3
+
+    public init(environment: any BundleEnvironment,
+                system: any JITSystem,
+                defaults: UserDefaults,
+                openURL: @escaping @MainActor (URL) async -> Bool,
+                clock: any JITClock,
+                bundleIdentifier: String?,
+                sentinel: ProbeSentinel,
+                store: JITStatusStore) {
+        self.environment = environment
+        self.system = system
+        self.defaults = defaults
+        self.openURL = openURL
+        self.clock = clock
+        self.bundleIdentifier = bundleIdentifier
+        self.sentinel = sentinel
+        self.store = store
+
+        let detected = detectInstallMethod(environment)
+        installMethod = detected.0
+        evidence = detected.1
+        isRequestingTrollStoreJIT = false
+        facts = JITFacts(
+            installMethod: detected.0,
+            csDebugged: false,
+            csDebuggedSeen: .never,
+            txm: TXMInfo(state: .unknown, enforced: true, basis: "not gathered"),
+            trollStoreRequest: .none,
+            probeBlockedBySentinel: false
+        )
+        lastProbe = ProbeOutcome(kind: .notRun, detail: "not gathered")
+        status = .placeholder
+        store.update(status)
+    }
+
+    /// Reads install method, CS_DEBUGGED, TXM and the crash sentinel, then probes when that is safe.
+    public func gatherFacts() {
+        let detected = detectInstallMethod(environment)
+        installMethod = detected.0
+        evidence = detected.1
+        let debugged = system.csDebugged()
+        facts = JITFacts(
+            installMethod: detected.0,
+            csDebugged: debugged,
+            csDebuggedSeen: debugged ? .atLaunch : .never,
+            txm: system.txm(osMajor: SystemInfo.osMajor, cpuFamily: SystemInfo.cpuFamily),
+            trollStoreRequest: .none,
+            probeBlockedBySentinel: sentinel.consumeAtLaunch()
+        )
+        lastProbe = ProbeOutcome(kind: .notRun, detail: nil)
+        runProbeIfAllowed()
+        publish()
+    }
+
+    /// First activation may ask TrollStore for JIT. Later ones notice JIT that appeared while backgrounded.
+    public func sceneBecameActive() {
+        if !hasActivated {
+            hasActivated = true
+            let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
+            if JITPolicy.shouldRequestTrollStoreJIT(
+                installMethod: facts.installMethod,
+                csDebugged: facts.csDebugged,
+                triedThisProcess: triedTrollStoreThisProcess,
+                lastAttempt: lastAttempt,
+                now: clock.now(),
+                manual: false
+            ) {
+                startTrollStoreRequest()
+                return
+            }
+            if isTrollStoreFamily, !facts.csDebugged {
+                facts.trollStoreRequest = .timedOut
+                publish()
+                return
+            }
+        }
+        recheckCSDebugged()
+    }
+
+    /// Retry JIT button. Cooldown does not apply; an in-flight request is left alone.
+    public func retryTrollStoreJIT() {
+        guard requestTask == nil else { return }
+        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
+        guard JITPolicy.shouldRequestTrollStoreJIT(
+            installMethod: facts.installMethod,
+            csDebugged: facts.csDebugged,
+            triedThisProcess: triedTrollStoreThisProcess,
+            lastAttempt: lastAttempt,
+            now: clock.now(),
+            manual: true
+        ) else { return }
+        startTrollStoreRequest()
+    }
+
+    /// Retry probe button. Clears a crash skip and a failed probe, then probes again when allowed.
+    public func retryProbe() {
+        facts.probeBlockedBySentinel = false
+        if lastProbe.kind != .passed {
+            lastProbe = ProbeOutcome(kind: .notRun, detail: nil)
+        }
+        let debugged = system.csDebugged()
+        if debugged {
+            if !facts.csDebugged {
+                facts.csDebuggedSeen = .onForeground
+            }
+            facts.csDebugged = true
+        }
+        runProbeIfAllowed()
+        publish()
+    }
+
+    /// Awaits the in-flight TrollStore request, if there is one.
+    func waitForPendingRequest() async {
+        await requestTask?.value
+    }
+
+    private var isTrollStoreFamily: Bool {
+        facts.installMethod == .trollStore || facts.installMethod == .trollStoreLite
+    }
+
+    private func publish() {
+        status = JITPolicy.status(facts, probe: lastProbe)
+        store.update(status)
+    }
+
+    private func runProbeIfAllowed() {
+        if lastProbe.kind == .passed { return }
+        guard JITPolicy.mayProbe(facts) else {
+            lastProbe = ProbeOutcome(kind: .notRun, detail: probeSkipDetail())
+            return
+        }
+        do {
+            try sentinel.arm()
+        } catch {
+            lastProbe = ProbeOutcome(kind: .notRun, detail: "sentinel")
+            return
+        }
+        lastProbe = system.probe()
+        sentinel.disarm()
+    }
+
+    private func probeSkipDetail() -> String {
+        if facts.installMethod == .simulator { return "simulator" }
+        if facts.probeBlockedBySentinel { return "skipped after crash" }
+        if facts.txm.enforced || facts.txm.state == .unknown { return "TXM" }
+        if !facts.csDebugged { return "no CS_DEBUGGED" }
+        return "not run"
+    }
+
+    private func recheckCSDebugged() {
+        guard requestTask == nil else { return }
+        let debugged = system.csDebugged()
+        guard debugged, !facts.csDebugged else { return }
+        facts.csDebugged = true
+        facts.csDebuggedSeen = .onForeground
+        runProbeIfAllowed()
+        publish()
+    }
+
+    private func startTrollStoreRequest() {
+        guard requestTask == nil else { return }
+        defaults.set(clock.now(), forKey: Self.lastAttemptKey)
+        defaults.synchronize()
+        triedTrollStoreThisProcess = true
+        isRequestingTrollStoreJIT = true
+        facts.trollStoreRequest = .pending
+        publish()
+
+        guard let url = trollStoreJITURL() else {
+            finishRequestTimedOut()
+            return
+        }
+
+        requestTask = Task { @MainActor in
+            let opened = await self.openURL(url)
+            if !opened {
+                self.finishRequestTimedOut()
+                self.requestTask = nil
+                return
+            }
+
+            let start = self.clock.now()
+            var arrived = false
+            while self.clock.now().timeIntervalSince(start) < Self.requestDeadline {
+                try? await self.clock.sleep(seconds: Self.pollInterval)
+                if self.system.csDebugged() {
+                    arrived = true
+                    break
+                }
+            }
+
+            if arrived {
+                self.facts.csDebugged = true
+                self.facts.csDebuggedSeen = .afterTrollStoreRequest
+                try? await self.clock.sleep(seconds: Self.gracePeriod)
+                self.runProbeIfAllowed()
+                self.facts.trollStoreRequest = .none
+                self.isRequestingTrollStoreJIT = false
+                self.publish()
+            } else {
+                self.finishRequestTimedOut()
+            }
+            self.requestTask = nil
+        }
+    }
+
+    private func finishRequestTimedOut() {
+        facts.trollStoreRequest = .timedOut
+        isRequestingTrollStoreJIT = false
+        publish()
+    }
+
+    private func trollStoreJITURL() -> URL? {
+        guard let bundleIdentifier else { return nil }
+        var components = URLComponents()
+        components.scheme = "apple-magnifier"
+        components.host = "enable-jit"
+        components.queryItems = [URLQueryItem(name: "bundle-id", value: bundleIdentifier)]
+        return components.url
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/JITStatusStore.swift b/Packages/EikonKit/Sources/EikonKit/JITStatusStore.swift
new file mode 100644
index 0000000..727a252
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/JITStatusStore.swift
@@ -0,0 +1,41 @@
+import Foundation
+
+extension JITStatus {
+    /// Conservative not-usable status for reads before facts have been gathered.
+    public static var placeholder: JITStatus {
+        let facts = JITFacts(
+            installMethod: .unknown,
+            csDebugged: false,
+            csDebuggedSeen: .never,
+            txm: TXMInfo(state: .unknown, enforced: true, basis: "not gathered"),
+            trollStoreRequest: .none,
+            probeBlockedBySentinel: false
+        )
+        return JITPolicy.status(facts, probe: ProbeOutcome(kind: .notRun, detail: "not gathered"))
+    }
+}
+
+/// Thread-safe snapshot for non-UI code.
+public final class JITStatusStore: @unchecked Sendable {
+    public static let shared = JITStatusStore()
+
+    private let lock = NSLock()
+    private var status: JITStatus
+
+    public init(initial: JITStatus = .placeholder) {
+        status = initial
+    }
+
+    /// Lock-protected read. Safe from any thread.
+    public var current: JITStatus {
+        lock.lock()
+        defer { lock.unlock() }
+        return status
+    }
+
+    func update(_ status: JITStatus) {
+        lock.lock()
+        self.status = status
+        lock.unlock()
+    }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/JITSystem.swift b/Packages/EikonKit/Sources/EikonKit/JITSystem.swift
new file mode 100644
index 0000000..c2933ba
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/JITSystem.swift
@@ -0,0 +1,43 @@
+import CEikonJIT
+import Foundation
+
+/// Seam over the C layer and sysctl so tests inject facts without a device.
+public protocol JITSystem: Sendable {
+    func csDebugged() -> Bool
+    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo
+    func probe() -> ProbeOutcome
+}
+
+public struct LiveJITSystem: JITSystem {
+    public init() {}
+
+    public func csDebugged() -> Bool {
+        var flags: UInt32 = 0
+        guard eikon_cs_flags(&flags) == 0 else { return false }
+        return (flags & UInt32(EIKON_CS_DEBUGGED)) != 0
+    }
+
+    public func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo {
+        #if targetEnvironment(simulator)
+        return TXMInfo(state: .absent, enforced: false, basis: "simulator")
+        #else
+        return JITPolicy.txmInfo(
+            firmware: Int32(eikon_txm_firmware_present()),
+            osMajor: osMajor,
+            cpuFamily: cpuFamily
+        )
+        #endif
+    }
+
+    public func probe() -> ProbeOutcome {
+        #if targetEnvironment(simulator)
+        return ProbeOutcome(kind: .notRun, detail: "simulator")
+        #else
+        return ProbeOutcome(eikon_jit_probe())
+        #endif
+    }
+}
+
+extension JITSystem where Self == LiveJITSystem {
+    public static var live: LiveJITSystem { LiveJITSystem() }
+}
diff --git a/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift b/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift
new file mode 100644
index 0000000..e703803
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/SystemInfo.swift
@@ -0,0 +1,29 @@
+import Darwin
+import Foundation
+
+/// Host facts reused by the JIT controller and, later, the device report.
+public enum SystemInfo {
+    public static var osMajor: Int {
+        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
+    }
+
+    /// `hw.cpufamily`, or 0 when the sysctl fails.
+    public static var cpuFamily: UInt32 {
+        var value: UInt32 = 0
+        var size = MemoryLayout<UInt32>.size
+        guard sysctlbyname("hw.cpufamily", &value, &size, nil, 0) == 0 else { return 0 }
+        return value
+    }
+
+    public static var isSimulator: Bool {
+        #if targetEnvironment(simulator)
+        true
+        #else
+        false
+        #endif
+    }
+
+    public static var buildNumber: String {
+        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/JITControllerTests.swift b/Packages/EikonKit/Tests/EikonKitTests/JITControllerTests.swift
new file mode 100644
index 0000000..ccfd816
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/JITControllerTests.swift
@@ -0,0 +1,202 @@
+import Foundation
+import Testing
+@testable import EikonKit
+
+/// Settable CS_DEBUGGED, a fixed absent TXM, and a probe that always passes.
+final class FakeJITSystem: JITSystem, @unchecked Sendable {
+    private let lock = NSLock()
+    private var debugged = false
+    private var probes = 0
+
+    var csDebuggedFlag: Bool {
+        get {
+            lock.lock()
+            defer { lock.unlock() }
+            return debugged
+        }
+        set {
+            lock.lock()
+            debugged = newValue
+            lock.unlock()
+        }
+    }
+
+    var probeCount: Int {
+        lock.lock()
+        defer { lock.unlock() }
+        return probes
+    }
+
+    func csDebugged() -> Bool { csDebuggedFlag }
+
+    func txm(osMajor: Int, cpuFamily: UInt32) -> TXMInfo {
+        TXMInfo(state: .absent, enforced: false, basis: "test")
+    }
+
+    func probe() -> ProbeOutcome {
+        lock.lock()
+        probes += 1
+        lock.unlock()
+        return ProbeOutcome(kind: .passed, detail: nil)
+    }
+}
+
+@MainActor
+final class URLRecorder {
+    private(set) var opened: [URL] = []
+    var result = true
+    var onOpen: (() -> Void)?
+
+    func open(_ url: URL) async -> Bool {
+        opened.append(url)
+        onOpen?()
+        return result
+    }
+}
+
+final class FakeClock: JITClock, @unchecked Sendable {
+    private let lock = NSLock()
+    private var current: Date
+
+    init(start: Date) {
+        current = start
+    }
+
+    func now() -> Date {
+        lock.lock()
+        defer { lock.unlock() }
+        return current
+    }
+
+    func sleep(seconds: Double) async throws {
+        advance(by: seconds)
+        await Task.yield()
+    }
+
+    private func advance(by seconds: Double) {
+        lock.lock()
+        current.addTimeInterval(seconds)
+        lock.unlock()
+    }
+}
+
+@MainActor
+private struct ControllerHarness {
+    let system = FakeJITSystem()
+    let recorder = URLRecorder()
+    let clock: FakeClock
+    let defaults: UserDefaults
+    let suiteName: String
+    let sentinelDirectory: URL
+    let store = JITStatusStore()
+    let controller: JITController
+    let bundleID = "com.example.sideload.rewritten"
+
+    init() {
+        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
+        clock = FakeClock(start: start)
+        suiteName = UUID().uuidString
+        defaults = UserDefaults(suiteName: suiteName)!
+        sentinelDirectory = FileManager.default.temporaryDirectory
+            .appendingPathComponent("jit-controller-\(UUID().uuidString)", isDirectory: true)
+
+        let bundleURL = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/EIKONTEST/Eikon.app")
+        let marker = bundleURL.deletingLastPathComponent().appendingPathComponent("_TrollStore").path
+        let environment = FakeBundleEnvironment(
+            bundleURL: bundleURL,
+            homeDirectory: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/EIKONDATA"),
+            existing: [URL(fileURLWithPath: marker).standardizedFileURL.path]
+        )
+        let sentinel = ProbeSentinel(directory: sentinelDirectory, buildNumber: "1")
+        let system = system
+        let recorder = recorder
+        controller = JITController(
+            environment: environment,
+            system: system,
+            defaults: defaults,
+            openURL: { url in await recorder.open(url) },
+            clock: clock,
+            bundleIdentifier: bundleID,
+            sentinel: sentinel,
+            store: store
+        )
+    }
+
+    func cleanup() {
+        defaults.removePersistentDomain(forName: suiteName)
+        try? FileManager.default.removeItem(at: sentinelDirectory)
+    }
+}
+
+@Test @MainActor func oneRequestNoBounce() async {
+    let harness = ControllerHarness()
+    defer { harness.cleanup() }
+
+    harness.controller.gatherFacts()
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+
+    #expect(harness.recorder.opened.count == 1)
+    #expect(harness.recorder.opened.first?.absoluteString.contains(harness.bundleID) == true)
+
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+    #expect(harness.recorder.opened.count == 1)
+}
+
+@Test @MainActor func jitArrivesFromTrollStore() async {
+    let harness = ControllerHarness()
+    defer { harness.cleanup() }
+    harness.recorder.onOpen = { harness.system.csDebuggedFlag = true }
+
+    harness.controller.gatherFacts()
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+
+    #expect(harness.controller.status.usable)
+    #expect(harness.controller.status.source == .trollStore)
+    #expect(!harness.controller.isRequestingTrollStoreJIT)
+}
+
+@Test @MainActor func deadlineWithoutReactivation() async {
+    let harness = ControllerHarness()
+    defer { harness.cleanup() }
+
+    harness.controller.gatherFacts()
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+
+    #expect(!harness.controller.status.usable)
+    #expect(harness.controller.status.reason == .trollStoreTimedOut)
+    #expect(!harness.controller.isRequestingTrollStoreJIT)
+}
+
+@Test @MainActor func openFailsWithoutWaiting() async {
+    let harness = ControllerHarness()
+    defer { harness.cleanup() }
+    harness.recorder.result = false
+    let start = harness.clock.now()
+
+    harness.controller.gatherFacts()
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+
+    #expect(harness.controller.status.reason == .trollStoreTimedOut)
+    #expect(!harness.controller.isRequestingTrollStoreJIT)
+    #expect(harness.clock.now() == start)
+}
+
+@Test @MainActor func storeMirrorsController() async {
+    let harness = ControllerHarness()
+    defer { harness.cleanup() }
+
+    harness.controller.gatherFacts()
+    #expect(harness.store.current == harness.controller.status)
+
+    harness.recorder.onOpen = { harness.system.csDebuggedFlag = true }
+    harness.controller.sceneBecameActive()
+    await harness.controller.waitForPendingRequest()
+
+    #expect(harness.store.current == harness.controller.status)
+    #expect(harness.controller.status.usable)
+}
