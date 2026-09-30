diff --git a/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift b/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift
index 790489e..c076609 100644
--- a/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift
+++ b/Packages/EikonKit/Sources/EikonKit/DeviceReport.swift
@@ -19,7 +19,8 @@ public struct DeviceReport: Codable, Sendable, Equatable {
 
     /// Assembles a report from facts that have already been gathered.
     public static func make(app: AppInfo, installMethod: InstallMethod, evidence: InstallEvidence,
-                            jit: JITStatus, system: DeviceSystem, now: Date) -> DeviceReport {
+                            jit: JITStatus, system: DeviceSystem, now: Date,
+                            gates: [String: GateResult] = [:]) -> DeviceReport {
         let seconds = now.timeIntervalSince1970.rounded(.down)
         return DeviceReport(
             schemaVersion: currentSchemaVersion,
@@ -34,7 +35,7 @@ public struct DeviceReport: Codable, Sendable, Equatable {
             install: InstallInfo(method: installMethod, evidence: evidence),
             jit: jit,
             memory: MemoryInfo(availableBytes: system.availableMemoryBytes()),
-            gates: [:],
+            gates: gates,
             notes: nil
         )
     }
diff --git a/Packages/EikonKit/Sources/EikonKit/Gates/GateStore.swift b/Packages/EikonKit/Sources/EikonKit/Gates/GateStore.swift
new file mode 100644
index 0000000..36bf0d8
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Gates/GateStore.swift
@@ -0,0 +1,170 @@
+import EikonCore
+import Foundation
+
+/// The build a gate result was measured under. A passed result counts only under the
+/// identical stamp.
+public struct BuildStamp: Codable, Sendable, Equatable {
+    /// App version and build together: a build number alone could repeat across versions.
+    public var app: String
+    /// OS build (`kern.osversion`), e.g. "21A329".
+    public var os: String
+
+    public init(app: String, os: String) {
+        self.app = app
+        self.os = os
+    }
+
+    /// The running app and OS build.
+    @MainActor
+    public static func live() -> BuildStamp {
+        let info = AppInfo.from(.main)
+        return BuildStamp(app: "\(info.version) (\(info.build))", os: LiveDeviceSystem.current().osBuild)
+    }
+}
+
+/// One stored gate result and the build it was measured under.
+public struct GateEntry: Sendable, Equatable {
+    public var name: GateName
+    public var result: GateResult
+    public var stamp: BuildStamp
+}
+
+/// Persisted device-gate results (`gates.json`). Lock-guarded; safe from any thread.
+/// A pass counts only under the build it was measured on and reads as unmeasured after an
+/// app or OS update. A failure stays a failure, marked stale, until the gate is recorded
+/// again. Later splits (05: x18, 07: guestWindow) call `record`; 02 writes nothing.
+public final class GateStore: @unchecked Sendable {
+    private let file: PersistedFile<GatesDocument>
+    private let stamp: BuildStamp
+    private let lock = NSLock()
+    private var document: GatesDocument
+    private var readOnly: Bool
+    private var changeHandler: (@Sendable () -> Void)?
+
+    /// `directory` is `…/Application Support/Eikon` (a temp directory in tests); `current`
+    /// is the build this process runs under.
+    public init(directory: URL, current: BuildStamp) {
+        file = PersistedFile(url: directory.appendingPathComponent("gates.json"))
+        stamp = current
+        do {
+            let loaded = try file.load()
+            document = loaded?.document ?? GatesDocument(gates: TolerantList())
+            readOnly = loaded?.isReadOnly ?? false
+        } catch {
+            // Present but unreadable: keep working in memory and never overwrite it.
+            document = GatesDocument(gates: TolerantList())
+            readOnly = true
+        }
+    }
+
+    /// Application Support/Eikon/gates.json, current app + OS build.
+    @MainActor
+    public static func live() -> GateStore {
+        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
+        return GateStore(directory: support.appendingPathComponent("Eikon"), current: .live())
+    }
+
+    /// Called after each `record`, off the caller's thread; LibraryController uses it to
+    /// recompute route decisions. Set once during app wiring.
+    public var onChange: (@Sendable () -> Void)? {
+        get { lock.withLock { changeHandler } }
+        set { lock.withLock { changeHandler = newValue } }
+    }
+
+    /// Stores `result` for `name` with the current build stamp, replacing any earlier
+    /// result for that gate, and persists it. `measuredAt` is kept to whole seconds, as
+    /// the file stores it.
+    public func record(_ name: GateName, _ result: GateResult) {
+        var result = result
+        result.measuredAt = Date(timeIntervalSince1970: result.measuredAt.timeIntervalSince1970.rounded(.down))
+        let gate = StoredGate(name: name.rawValue, result: result, stamp: stamp)
+        let handler = lock.withLock {
+            document.gates.elements.removeAll { $0.name == gate.name }
+            document.gates.elements.append(gate)
+            if !readOnly { try? file.save(document) }
+            return changeHandler
+        }
+        if let handler {
+            DispatchQueue.global().async(execute: handler)
+        }
+    }
+
+    /// Every stored gate mapped through the expiry rules. Gates never recorded are absent,
+    /// and the picker treats a missing gate as unmeasured.
+    public func states() -> [GateName: GateState] {
+        lock.withLock {
+            Dictionary(document.gates.elements.map { (GateName(rawValue: $0.name), state(of: $0)) },
+                       uniquingKeysWith: { _, last in last })
+        }
+    }
+
+    /// Results still meaningful on this build, for DeviceReport.make: everything measured
+    /// under the current build, plus every failure with its original date.
+    public func current() -> [String: GateResult] {
+        lock.withLock {
+            Dictionary(document.gates.elements
+                .filter { $0.result.passed == false || $0.stamp == stamp }
+                .map { ($0.name, $0.result) },
+                uniquingKeysWith: { _, last in last })
+        }
+    }
+
+    /// Everything stored, with the stamp each result was measured under.
+    public func entries() -> [GateEntry] {
+        lock.withLock {
+            document.gates.elements.map { GateEntry(name: GateName(rawValue: $0.name), result: $0.result, stamp: $0.stamp) }
+        }
+    }
+
+    private func state(of gate: StoredGate) -> GateState {
+        switch (gate.result.passed, gate.stamp == stamp) {
+        case (true?, true): .passed
+        case (true?, false): .unmeasured
+        case (false?, let sameBuild): .failed(stale: !sameBuild)
+        case (nil, _): .unmeasured
+        }
+    }
+}
+
+private struct GatesDocument: PersistedDocument {
+    static let currentFormat = 1
+    var gates: TolerantList<StoredGate>
+}
+
+/// A gate keyed by its raw name, so gates this build doesn't know round-trip.
+/// `measuredAt` is ISO-8601, as in DeviceReport.
+private struct StoredGate: Codable, Sendable {
+    var name: String
+    var result: GateResult
+    var stamp: BuildStamp
+
+    private enum Key: String, CodingKey { case name, result, stamp }
+    private enum ResultKey: String, CodingKey { case passed, detail, measuredAt }
+
+    init(name: String, result: GateResult, stamp: BuildStamp) {
+        self.name = name
+        self.result = result
+        self.stamp = stamp
+    }
+
+    init(from decoder: any Decoder) throws {
+        let container = try decoder.container(keyedBy: Key.self)
+        name = try container.decode(String.self, forKey: .name)
+        stamp = try container.decode(BuildStamp.self, forKey: .stamp)
+        let nested = try container.nestedContainer(keyedBy: ResultKey.self, forKey: .result)
+        let measuredAt = try nested.decode(String.self, forKey: .measuredAt)
+        result = GateResult(passed: try nested.decodeIfPresent(Bool.self, forKey: .passed),
+                            detail: try nested.decode(String.self, forKey: .detail),
+                            measuredAt: try Date(measuredAt, strategy: .iso8601))
+    }
+
+    func encode(to encoder: any Encoder) throws {
+        var container = encoder.container(keyedBy: Key.self)
+        try container.encode(name, forKey: .name)
+        try container.encode(stamp, forKey: .stamp)
+        var nested = container.nestedContainer(keyedBy: ResultKey.self, forKey: .result)
+        try nested.encodeIfPresent(result.passed, forKey: .passed)
+        try nested.encode(result.detail, forKey: .detail)
+        try nested.encode(result.measuredAt.formatted(.iso8601), forKey: .measuredAt)
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift b/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift
index 28e27ca..bd6c15c 100644
--- a/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift
+++ b/Packages/EikonKit/Tests/EikonKitTests/DeviceReportTests.swift
@@ -39,6 +39,22 @@ private struct FixedDeviceSystem: DeviceSystem {
     try expectPrivacy(try live.encode())
 }
 
+@Test func reportIncludesGateStoreResults() throws {
+    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
+    let gates = GateStore(directory: directory, current: BuildStamp(app: "A1", os: "O1"))
+    let measured = GateResult(passed: false, detail: "trapped", measuredAt: Date(timeIntervalSince1970: 1_768_470_030))
+    gates.record(.x18, measured)
+
+    let report = DeviceReport.make(
+        app: AppInfo(version: "0.1.0", build: "12", commit: "0123abc", packageKind: "ipa",
+                     bundleIdentifier: "com.getboolean.eikon"),
+        installMethod: .simulator,
+        evidence: InstallEvidence(bundlePath: "", homeDirectory: "", markers: []),
+        jit: .placeholder, system: FixedDeviceSystem(), now: Date(), gates: gates.current()
+    )
+    #expect(try DeviceReport.decode(report.encode()).gates["x18"] == measured)
+}
+
 @Test func fixtureContract() throws {
     let url = try repoFile("tests/fixtures/device-report.json")
     let fixtureData = try Data(contentsOf: url)
diff --git a/Packages/EikonKit/Tests/EikonKitTests/GateStoreTests.swift b/Packages/EikonKit/Tests/EikonKitTests/GateStoreTests.swift
new file mode 100644
index 0000000..51c01e6
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/GateStoreTests.swift
@@ -0,0 +1,52 @@
+import EikonCore
+import Foundation
+import Testing
+@testable import EikonKit
+
+/// A store over `directory` that believes it runs under `app`/`os`.
+private func store(_ directory: URL, app: String = "A1", os: String = "O1") -> GateStore {
+    GateStore(directory: directory, current: BuildStamp(app: app, os: os))
+}
+
+private func temporaryDirectory() throws -> URL {
+    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
+    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
+    return url
+}
+
+private func result(_ passed: Bool?) -> GateResult {
+    GateResult(passed: passed, detail: "measured", measuredAt: Date(timeIntervalSince1970: 1_768_470_030))
+}
+
+@Test func passedResultExpiresUnderAnotherBuild() throws {
+    let directory = try temporaryDirectory()
+    store(directory).record(.x18, result(true))
+
+    #expect(store(directory).states()[.x18] == .passed)
+    #expect(store(directory).current()[GateName.x18.rawValue] == result(true))
+    #expect(store(directory, app: "A2").states()[.x18] == .unmeasured)
+    #expect(store(directory, os: "O2").states()[.x18] == .unmeasured)
+    #expect(store(directory, app: "A2").current()[GateName.x18.rawValue] == nil)
+}
+
+@Test func failedResultTurnsStaleUnderAnotherBuildUntilRecordedAgain() throws {
+    let directory = try temporaryDirectory()
+    store(directory).record(.x18, result(false))
+
+    let updated = store(directory, app: "A2")
+    #expect(updated.states()[.x18] == .failed(stale: true))
+    #expect(updated.current()[GateName.x18.rawValue] == result(false))
+
+    updated.record(.x18, result(true))
+    #expect(store(directory, app: "A2").states()[.x18] == .passed)
+    updated.record(.x18, result(false))
+    #expect(store(directory, app: "A2").states()[.x18] == .failed(stale: false))
+}
+
+@Test func unknownGateNameSurvivesReload() throws {
+    let directory = try temporaryDirectory()
+    let future = GateName(rawValue: "futureGate")
+    store(directory).record(future, result(true))
+
+    #expect(store(directory).states()[future] == .passed)
+}
