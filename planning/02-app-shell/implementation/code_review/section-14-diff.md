diff --git a/App/Device/DeveloperSection.swift b/App/Device/DeveloperSection.swift
new file mode 100644
index 0000000..68c41b6
--- /dev/null
+++ b/App/Device/DeveloperSection.swift
@@ -0,0 +1,160 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// One raw gate store entry, uninterpreted.
+struct GateStoreEntryRow: Identifiable {
+    var name: GateName
+    var passed: Bool?
+    var appBuild: String
+    var osBuild: String
+    var measuredAt: Date
+    var detail: String
+    var id: String { name.rawValue }
+
+    init(_ entry: GateEntry) {
+        name = entry.name
+        passed = entry.result.passed
+        appBuild = entry.stamp.app
+        osBuild = entry.stamp.os
+        measuredAt = entry.result.measuredAt
+        detail = entry.result.detail
+    }
+}
+
+struct DeveloperRows {
+    var replicaID: String
+    /// This device's settings file was from a newer build, so the store forked to a new replica.
+    var settingsForked: Bool
+    var gateEntries: [GateStoreEntryRow]
+    /// Disables the test buttons while a session runs.
+    var sessionActive: Bool
+    /// The last test session couldn't start.
+    var testSessionFailed: Bool
+}
+
+/// Developer tools, in every build, collapsed by default.
+struct DeveloperSection: View {
+    let rows: DeveloperRows
+    let onRunTestSession: () -> Void
+    let onSimulateCrash: () -> Void
+    @State private var isExpanded: Bool
+
+    init(rows: DeveloperRows, onRunTestSession: @escaping () -> Void, onSimulateCrash: @escaping () -> Void,
+         isExpanded: Bool = false) {
+        self.rows = rows
+        self.onRunTestSession = onRunTestSession
+        self.onSimulateCrash = onSimulateCrash
+        _isExpanded = State(initialValue: isExpanded)
+    }
+
+    var body: some View {
+        Section {
+            DisclosureGroup(isExpanded: $isExpanded) {
+                if rows.settingsForked {
+                    Label {
+                        Text("developer.settingsForked")
+                            .font(.footnote)
+                            .foregroundColor(.secondary)
+                    } icon: {
+                        Image(systemName: "exclamationmark.triangle.fill")
+                            .foregroundColor(.orange)
+                    }
+                }
+                Button("developer.runTestSession", action: onRunTestSession)
+                    .disabled(rows.sessionActive)
+                VStack(alignment: .leading, spacing: 4) {
+                    Button("developer.simulateCrash", action: onSimulateCrash)
+                        .disabled(rows.sessionActive)
+                    Text("developer.simulateCrash.footnote")
+                        .font(.footnote)
+                        .foregroundColor(.secondary)
+                }
+                if rows.testSessionFailed {
+                    Text("developer.testSession.failed")
+                        .font(.footnote)
+                        .foregroundColor(.secondary)
+                }
+                VStack(alignment: .leading, spacing: 4) {
+                    Text("developer.replicaID")
+                    Text(verbatim: rows.replicaID)
+                        .font(.footnote.monospaced())
+                        .foregroundColor(.secondary)
+                        .textSelection(.enabled)
+                }
+                gateStore
+            } label: {
+                Text("status.section.developer")
+            }
+        }
+    }
+
+    @ViewBuilder
+    private var gateStore: some View {
+        Text("developer.gates")
+        if rows.gateEntries.isEmpty {
+            Text("developer.gates.empty")
+                .foregroundColor(.secondary)
+        } else {
+            ForEach(rows.gateEntries) { entry in
+                VStack(alignment: .leading, spacing: 2) {
+                    HStack {
+                        Text(verbatim: entry.name.rawValue)
+                            .font(.body.monospaced())
+                        Spacer()
+                        Text(Self.resultKey(entry.passed))
+                            .foregroundColor(.secondary)
+                    }
+                    Group {
+                        Text(L10n.format("developer.gates.stamp", entry.appBuild, entry.osBuild))
+                        Text(verbatim: GateTableSection.dateFormatter.string(from: entry.measuredAt))
+                        if !entry.detail.isEmpty {
+                            Text(verbatim: entry.detail)
+                        }
+                    }
+                    .font(.footnote)
+                    .foregroundColor(.secondary)
+                    .textSelection(.enabled)
+                }
+            }
+        }
+    }
+
+    /// The stored result as written, not mapped through the build-expiry rules.
+    private static func resultKey(_ passed: Bool?) -> LocalizedStringKey {
+        switch passed {
+        case true?: "developer.gates.result.passed"
+        case false?: "developer.gates.result.failed"
+        case nil: "developer.gates.result.unmeasured"
+        }
+    }
+}
+
+#if DEBUG
+struct DeveloperSection_Previews: PreviewProvider {
+    static let entries = [
+        GateStoreEntryRow(GateEntry(name: .x18, result: GateResult(passed: true, detail: "sample detail", measuredAt: Date()),
+                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
+        GateStoreEntryRow(GateEntry(name: .guestWindow, result: GateResult(passed: false, detail: "", measuredAt: Date()),
+                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
+        GateStoreEntryRow(GateEntry(name: GateName(rawValue: "futureGate"),
+                                    result: GateResult(passed: nil, detail: "", measuredAt: Date()),
+                                    stamp: BuildStamp(app: "1.0 (1) abc1234", os: "23A341"))),
+    ]
+
+    static func rows(entries: [GateStoreEntryRow], forked: Bool) -> DeveloperRows {
+        DeveloperRows(replicaID: UUID().uuidString.lowercased(), settingsForked: forked, gateEntries: entries,
+                      sessionActive: false, testSessionFailed: forked)
+    }
+
+    static var previews: some View {
+        List {
+            DeveloperSection(rows: rows(entries: [], forked: false), onRunTestSession: {}, onSimulateCrash: {},
+                             isExpanded: true)
+            DeveloperSection(rows: rows(entries: entries, forked: true), onRunTestSession: {}, onSimulateCrash: {},
+                             isExpanded: true)
+        }
+        .listStyle(.insetGrouped)
+    }
+}
+#endif
diff --git a/App/Device/RouteTableSection.swift b/App/Device/RouteTableSection.swift
new file mode 100644
index 0000000..2f757ac
--- /dev/null
+++ b/App/Device/RouteTableSection.swift
@@ -0,0 +1,156 @@
+import EikonCore
+import EikonKit
+import SwiftUI
+
+/// One route as this device would run it, independent of any game.
+struct RouteRow: Identifiable {
+    var route: RouteID
+    var verdict: RouteVerdict
+    var reasons: [RouteReason]
+    var id: RouteID { route }
+}
+
+struct GateRow: Identifiable {
+    var name: GateName
+    var state: GateState
+    /// From the stored result still meaningful on this build, if any.
+    var detail: String?
+    var measuredAt: Date?
+    var id: String { name.rawValue }
+}
+
+/// Each route's own candidate, judged against a synthetic game that exercises its full
+/// rule set. In memory only: no files, no names.
+enum DeviceRouteTable {
+    static func rows(environment: RouteEnvironment) -> [RouteRow] {
+        RouteID.allCases.compactMap { route in
+            let decision = RoutePicker.decide(detection: detection(for: route), environment: environment, override: nil)
+            guard let candidate = decision.candidates.first(where: { $0.route == route }) else { return nil }
+            // Ordering reasons compare routes for a game; they don't say whether this one works.
+            let reasons = candidate.reasons.filter { $0 != .nativeFirst && $0 != .fexPreferredWithJIT }
+            return RouteRow(route: route, verdict: candidate.verdict, reasons: reasons)
+        }
+    }
+
+    /// The x86 Windows routes get an i386 program, which needs every gate; Linux gets amd64.
+    private static func detection(for route: RouteID) -> DetectionResult {
+        let windows = ExecutableInfo(path: "Game.exe", format: .pe, architecture: .i386, machine: 0x14c, isGUI: true)
+        let linux = ExecutableInfo(path: "Game", format: .elf, architecture: .amd64, machine: 62, isGUI: nil)
+        let (engine, executables): (Engine, [GamePlatform: ExecutableInfo]) = switch route {
+        case .nativeKirikiri: (.kirikiri, [.windows: windows])
+        case .nativeRenPy: (.renpy, [.windows: windows])
+        case .wineFEX, .wineBox64: (.unknown, [.windows: windows])
+        case .linuxFEX: (.unknown, [.linux: linux])
+        }
+        return DetectionResult(engine: engine, details: EngineDetails(), gameRoot: "", executables: executables,
+                               keyFile: nil, detectorVersion: GameDetector.version)
+    }
+
+    /// The known gates first, then any other the store has, by name.
+    static func gateRows(states: [GateName: GateState], current: [String: GateResult]) -> [GateRow] {
+        let known: [GateName] = [.x18, .guestWindow]
+        let others = states.keys.filter { !known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
+        return (known + others).map { name in
+            let result = current[name.rawValue]
+            return GateRow(name: name, state: states[name] ?? .unmeasured, detail: result?.detail,
+                           measuredAt: result?.measuredAt)
+        }
+    }
+}
+
+struct RouteTableSection: View {
+    let routes: [RouteRow]
+    let jitReason: JITReasonCode?
+
+    var body: some View {
+        Section(header: Text("status.section.routes")) {
+            ForEach(routes) { row in
+                VStack(alignment: .leading, spacing: 4) {
+                    HStack(alignment: .firstTextBaseline) {
+                        Text(RouteStrings.name(row.route))
+                        Spacer()
+                        Text(RouteStrings.verdictKey(row.verdict))
+                            .foregroundColor(row.verdict.isRunnable ? .green : .secondary)
+                    }
+                    Text(RouteStrings.servesKey(row.route))
+                        .font(.caption)
+                        .foregroundColor(.secondary)
+                    ForEach(row.reasons.indices, id: \.self) { index in
+                        Text(RouteStrings.reasonText(row.reasons[index], jitReason: jitReason))
+                            .font(.footnote)
+                    }
+                }
+            }
+        }
+    }
+}
+
+struct GateTableSection: View {
+    let gates: [GateRow]
+
+    var body: some View {
+        Section(header: Text("status.section.gates")) {
+            ForEach(gates) { gate in
+                VStack(alignment: .leading, spacing: 4) {
+                    HStack {
+                        Text(GateStrings.name(gate.name))
+                        Spacer()
+                        Text(GateStrings.stateKey(gate.state))
+                            .foregroundColor(.secondary)
+                    }
+                    if let line = detailLine(gate) {
+                        Text(verbatim: line)
+                            .font(.footnote)
+                            .foregroundColor(.secondary)
+                            .textSelection(.enabled)
+                    }
+                }
+            }
+        }
+    }
+
+    private func detailLine(_ gate: GateRow) -> String? {
+        let parts = [gate.detail, gate.measuredAt.map(Self.dateFormatter.string)].compactMap { $0 }.filter { !$0.isEmpty }
+        return parts.isEmpty ? nil : parts.joined(separator: " · ")
+    }
+
+    static let dateFormatter: DateFormatter = {
+        let formatter = DateFormatter()
+        formatter.dateStyle = .medium
+        formatter.timeStyle = .short
+        return formatter
+    }()
+}
+
+#if DEBUG
+struct RouteTableSection_Previews: PreviewProvider {
+    /// Every verdict, and every reason a device row can show.
+    static let routes: [RouteRow] = [
+        RouteRow(route: .nativeKirikiri, verdict: .runnable, reasons: []),
+        RouteRow(route: .nativeRenPy, verdict: .planned, reasons: [.notInThisBuild]),
+        RouteRow(route: .wineFEX, verdict: .unavailable, reasons: [.needsJIT]),
+        RouteRow(route: .wineBox64, verdict: .runnableWithWarnings,
+                 reasons: [.gateUnmeasured(.x18), .gateUnmeasured(.guestWindow), .fexPreferredWithJIT]),
+        RouteRow(route: .linuxFEX, verdict: .unavailable,
+                 reasons: [.gateFailed(.x18, stale: true), .gateFailed(.guestWindow, stale: false)]),
+    ]
+
+    static let states: [GateState] = [.passed, .failed(stale: false), .failed(stale: true), .unmeasured]
+
+    /// Both known gates in one state, plus an unknown gate.
+    static func gates(_ state: GateState) -> [GateRow] {
+        [GateName.x18, .guestWindow, GateName(rawValue: "futureGate")].map {
+            GateRow(name: $0, state: state, detail: state == .unmeasured ? nil : "sample detail",
+                    measuredAt: state == .unmeasured ? nil : Date())
+        }
+    }
+
+    static var previews: some View {
+        List {
+            RouteTableSection(routes: routes, jitReason: .sideloadedNoJIT)
+            ForEach(states.indices, id: \.self) { GateTableSection(gates: gates(states[$0])) }
+        }
+        .listStyle(.insetGrouped)
+    }
+}
+#endif
diff --git a/App/StatusView.swift b/App/Device/StatusView.swift
similarity index 85%
rename from App/StatusView.swift
rename to App/Device/StatusView.swift
index ab3307a..e6c8753 100644
--- a/App/StatusView.swift
+++ b/App/Device/StatusView.swift
@@ -1,10 +1,20 @@
+import EikonCore
 import EikonKit
 import SwiftUI
 
-/// Eikon's one screen. Observes the controller so JIT rows update live, and
-/// reads the static device facts once.
+/// The "This device" screen. Observes the controller so JIT and route rows update live,
+/// and reads the static device facts once.
 struct StatusView: View {
     @ObservedObject var controller: JITController
+    @ObservedObject var presenter: SessionPresenter
+    let gates: GateStore
+    let settings: SettingsController
+    let registry: RuntimeRegistry
+
+    @State private var routes: [RouteRow] = []
+    @State private var gateRows: [GateRow] = []
+    @State private var gateEntries: [GateStoreEntryRow] = []
+    @State private var testSessionFailed = false
 
     @State private var deviceSystem: LiveDeviceSystem?
     @State private var device: DeviceRows?
@@ -25,12 +35,44 @@ struct StatusView: View {
             onRetryJIT: { controller.retryTrollStoreJIT() },
             onRetryProbe: { controller.retryProbe() },
             onCopyReport: copyReport,
-            onShareReport: shareReport
+            onShareReport: shareReport,
+            routes: routes,
+            gates: gateRows,
+            developer: DeveloperRows(replicaID: settings.replicaID.description, settingsForked: settings.forkedFrom != nil,
+                                     gateEntries: gateEntries, sessionActive: presenter.isSessionActive,
+                                     testSessionFailed: testSessionFailed),
+            onRunTestSession: { runTestSession(crash: false) },
+            onSimulateCrash: { runTestSession(crash: true) }
         )
         .sheet(item: $shareItem) { item in
             ActivityView(items: [item.url])
         }
-        .onAppear(perform: loadDeviceFacts)
+        .onAppear {
+            loadDeviceFacts()
+            refreshRoutes()
+        }
+        .onChange(of: controller.status) { _ in refreshRoutes() }
+    }
+
+    /// Nothing writes gates in 02, so JIT changes and appearing are enough.
+    private func refreshRoutes() {
+        let states = gates.states()
+        routes = DeviceRouteTable.rows(environment: RouteEnvironment(
+            jitUsable: controller.status.usable, gates: states, builtRoutes: registry.builtRoutes, runtimeChecks: [:]))
+        gateRows = DeviceRouteTable.gateRows(states: states, current: gates.current())
+        gateEntries = gates.entries().map(GateStoreEntryRow.init)
+    }
+
+    private func runTestSession(crash: Bool) {
+        testSessionFailed = false
+        Task {
+            do {
+                try await presenter.launchTest(try TestSession.game(),
+                                               runtime: crash ? CrashingTestPatternRuntime.self : TestPatternRuntime.self)
+            } catch {
+                testSessionFailed = true
+            }
+        }
     }
 
     private var appRows: AppInfoRows {
@@ -68,7 +110,8 @@ struct StatusView: View {
             evidence: controller.evidence,
             jit: controller.status,
             system: deviceSystem,
-            now: Date()
+            now: Date(),
+            gates: gates.current()
         )
     }
 
@@ -110,6 +153,11 @@ struct StatusContent: View {
     let onRetryProbe: () -> Void
     let onCopyReport: () -> Void
     let onShareReport: () -> Void
+    let routes: [RouteRow]
+    let gates: [GateRow]
+    let developer: DeveloperRows
+    let onRunTestSession: () -> Void
+    let onSimulateCrash: () -> Void
 
     /// No navigation view of its own: RootView's column navigation hosts it.
     var body: some View {
@@ -117,8 +165,11 @@ struct StatusContent: View {
             appSection
             installSection
             jitSection
+            RouteTableSection(routes: routes, jitReason: status.reason)
+            GateTableSection(gates: gates)
             deviceSection
             reportSection
+            DeveloperSection(rows: developer, onRunTestSession: onRunTestSession, onSimulateCrash: onSimulateCrash)
         }
         .listStyle(.insetGrouped)
         .navigationTitle(Text("status.title"))
@@ -437,7 +488,10 @@ private func sampleContent(status: JITStatus, method: InstallMethod, pending: Bo
     NavigationView {
         StatusContent(app: sampleApp, installMethod: method, status: status,
                       isRequestingTrollStoreJIT: pending, device: sampleDevice, copied: false, reportError: false,
-                      onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {})
+                      onRetryJIT: {}, onRetryProbe: {}, onCopyReport: {}, onShareReport: {},
+                      routes: RouteTableSection_Previews.routes, gates: RouteTableSection_Previews.gates(.unmeasured),
+                      developer: DeveloperSection_Previews.rows(entries: [], forked: false),
+                      onRunTestSession: {}, onSimulateCrash: {})
     }
     .navigationViewStyle(.stack)
 }
diff --git a/App/RootView.swift b/App/RootView.swift
index 30c9fc0..b20d127 100644
--- a/App/RootView.swift
+++ b/App/RootView.swift
@@ -78,7 +78,9 @@ struct RootView: View {
         switch target {
         case .library: LibraryView(services: services)
         case .drives: DrivesView(library: services.library)
-        case .device: StatusView(controller: jit)
+        case .device:
+            StatusView(controller: jit, presenter: services.presenter, gates: services.gates, settings: services.settings,
+                       registry: services.registry)
         case .credits: DestinationPlaceholder(titleKey: "credits.title")
         }
     }
diff --git a/App/Session/SessionPresenter.swift b/App/Session/SessionPresenter.swift
index 7062579..1ec77ca 100644
--- a/App/Session/SessionPresenter.swift
+++ b/App/Session/SessionPresenter.swift
@@ -5,22 +5,24 @@ import UIKit
 /// The one way a game session starts: the Launch button (section 13) and the developer
 /// test sessions (section 14). Refuses a second session while one is active.
 @MainActor
-final class SessionPresenter {
+final class SessionPresenter: ObservableObject {
     enum Failure: Error {
         case sessionActive, noWindow, driveNotConnected
     }
 
     private let library: LibraryController
     private let settings: SettingsController
-    private var active: GameSessionHostViewController?
+    /// Developer tools disable their buttons while a session runs.
+    @Published private(set) var isSessionActive = false
+    private var active: GameSessionHostViewController? {
+        didSet { isSessionActive = active != nil }
+    }
 
     init(library: LibraryController, settings: SettingsController) {
         self.library = library
         self.settings = settings
     }
 
-    var isSessionActive: Bool { active != nil }
-
     /// Runs the game from `location`. The drive opens once, here, and stays open for the
     /// whole session, so the game root and the access belong to the same resolution.
     func launch(_ location: GameLocation, game: GameID, route: RouteID, runtime: any GameRuntime.Type) async throws {
diff --git a/App/Session/TestPatternRuntime.swift b/App/Session/TestPatternRuntime.swift
new file mode 100644
index 0000000..61d7264
--- /dev/null
+++ b/App/Session/TestPatternRuntime.swift
@@ -0,0 +1,250 @@
+import CryptoKit
+import Darwin
+import EikonCore
+import EikonKit
+import Metal
+import QuartzCore
+import UIKit
+
+/// The developer test session: a synthetic game that needs no drive.
+enum TestSession {
+    /// Fixed and derived from a constant, so it encodes nothing about any game; its first 8
+    /// characters are the report id in crash issues.
+    static let gameID: GameID = {
+        var bytes = Array(SHA256.hash(data: Data("eikon.test-session".utf8)).prefix(16))
+        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 (name-based)
+        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
+        let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
+        return GameID(uuid: UUID(uuid: uuid))
+    }()
+
+    /// A scratch root under Caches; no game files.
+    static func game() throws -> LaunchableGame {
+        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
+            .appendingPathComponent("test-session", isDirectory: true)
+        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
+        let detection = DetectionResult(engine: .unknown, details: EngineDetails(), gameRoot: "", executables: [:],
+                                        keyFile: nil, detectorVersion: GameDetector.version)
+        return LaunchableGame(gameID: gameID, root: root, detection: detection, route: TestPatternRuntime.route)
+    }
+}
+
+enum TestPatternError: Error {
+    case metalUnavailable
+}
+
+/// Developer only: draws an animated pattern from its own render thread, holding the render
+/// gate around every commit, and counts command-buffer errors. Any commit while the app is
+/// inactive shows up as an error. Not a route: never registered, so `route` (which the
+/// protocol requires) is never offered; the session records its route as "test".
+@MainActor
+class TestPatternRuntime: GameRuntime {
+    nonisolated static var route: RouteID { .wineFEX }
+
+    nonisolated static func check(_ detection: DetectionResult, root: URL) async -> RuntimeCheck { .ok }
+
+    /// Seconds after launch until the app aborts; nil for a normal session.
+    class var crashDelay: TimeInterval? { nil }
+
+    private let shared = RenderShared()
+    private var metalView: MetalView?
+    private var errorLabel: UILabel?
+    private var labelTimer: Timer?
+    private var renderThread: Thread?
+    private var stopped = false
+
+    required init() {}
+
+    func launch(_ game: LaunchableGame, in host: any GameSessionHost) async throws {
+        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
+            throw TestPatternError.metalUnavailable
+        }
+        let view = MetalView(shared: shared)
+        view.frame = host.contentView.bounds
+        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
+        view.metalLayer.device = device
+        view.metalLayer.pixelFormat = .bgra8Unorm
+        view.metalLayer.framebufferOnly = true
+        host.contentView.addSubview(view)
+        metalView = view
+
+        let label = UILabel()
+        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
+        label.textColor = .white
+        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
+        label.translatesAutoresizingMaskIntoConstraints = false
+        host.contentView.addSubview(label)
+        NSLayoutConstraint.activate([
+            label.leadingAnchor.constraint(equalTo: host.contentView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
+            label.bottomAnchor.constraint(equalTo: host.contentView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
+        ])
+        errorLabel = label
+        let shared = shared
+        label.text = L10n.format("developer.testPattern.errors", shared.errorCount)
+        labelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak label] _ in
+            MainActor.assumeIsolated {
+                label?.text = L10n.format("developer.testPattern.errors", shared.errorCount)
+            }
+        }
+
+        let target = RenderTarget(layer: view.metalLayer, queue: queue, gate: host.renderGate, shared: shared)
+        let thread = Thread { target.run() }
+        thread.name = "eikon.test-pattern.render"
+        renderThread = thread
+        thread.start()
+
+        if let delay = Self.crashDelay {
+            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { abort() }
+        }
+    }
+
+    func pause() {
+        shared.setPaused(true)
+    }
+
+    func resume() {
+        shared.setPaused(false)
+    }
+
+    /// Waits for the render thread at most about a second, never unbounded, and off the
+    /// main thread.
+    func stop() async {
+        guard !stopped else { return }
+        stopped = true
+        shared.requestStop()
+        if renderThread != nil {
+            let exited = shared.exited
+            await withCheckedContinuation { continuation in
+                DispatchQueue.global(qos: .userInitiated).async {
+                    _ = exited.wait(timeout: .now() + 1)
+                    continuation.resume()
+                }
+            }
+        }
+        renderThread = nil
+        labelTimer?.invalidate()
+        labelTimer = nil
+        errorLabel?.removeFromSuperview()
+        errorLabel = nil
+        metalView?.removeFromSuperview()
+        metalView = nil
+    }
+}
+
+/// The simulated-crash session: the same pattern, then `abort()` about 5 s after launch.
+final class CrashingTestPatternRuntime: TestPatternRuntime {
+    override class var crashDelay: TimeInterval? { 5 }
+}
+
+/// Everything the render thread shares with the main thread, under one lock.
+private final class RenderShared: @unchecked Sendable {
+    private let lock = NSLock()
+    private var stopRequested = false
+    private var paused = false
+    private var size = CGSize.zero
+    private var errors = 0
+    private var clock: TimeInterval = 0
+    private var lastTick: TimeInterval?
+    let exited = DispatchSemaphore(value: 0)
+
+    var isStopRequested: Bool { lock.withLock { stopRequested } }
+    var drawableSize: CGSize {
+        get { lock.withLock { size } }
+        set { lock.withLock { size = newValue } }
+    }
+    var errorCount: Int { lock.withLock { errors } }
+
+    func requestStop() { lock.withLock { stopRequested = true } }
+    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
+    func addError() { lock.withLock { errors += 1 } }
+
+    /// Animation time, frozen while paused.
+    func tick(now: TimeInterval) -> TimeInterval {
+        lock.withLock {
+            if let lastTick, !paused { clock += now - lastTick }
+            lastTick = now
+            return clock
+        }
+    }
+}
+
+/// What the render thread holds. The layer and queue are used only from that thread once
+/// it starts (the main thread only resizes through `RenderShared`).
+private final class RenderTarget: @unchecked Sendable {
+    private let layer: CAMetalLayer
+    private let queue: any MTLCommandQueue
+    private let gate: RenderGate
+    private let shared: RenderShared
+
+    init(layer: CAMetalLayer, queue: any MTLCommandQueue, gate: RenderGate, shared: RenderShared) {
+        self.layer = layer
+        self.queue = queue
+        self.gate = gate
+        self.shared = shared
+    }
+
+    func run() {
+        defer { shared.exited.signal() }
+        while !shared.isStopRequested {
+            autoreleasepool { frame() }
+            Thread.sleep(forTimeInterval: 1.0 / 60)
+        }
+    }
+
+    /// The drawable comes before the gate, so a blocking `nextDrawable` never holds the gate
+    /// open while the host is closing it. Nothing here waits on the main thread.
+    private func frame() {
+        let size = shared.drawableSize
+        guard size.width > 0, size.height > 0 else { return }
+        if layer.drawableSize != size { layer.drawableSize = size }
+        guard let drawable = layer.nextDrawable() else { return }
+        guard gate.enter() else { return }
+        defer { gate.leave() }
+
+        let time = shared.tick(now: ProcessInfo.processInfo.systemUptime)
+        // The pattern: a clear color cycling through hues.
+        let pass = MTLRenderPassDescriptor()
+        pass.colorAttachments[0].texture = drawable.texture
+        pass.colorAttachments[0].loadAction = .clear
+        pass.colorAttachments[0].storeAction = .store
+        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5 + 0.5 * sin(time), green: 0.5 + 0.5 * sin(time + 2.1),
+                                                            blue: 0.5 + 0.5 * sin(time + 4.2), alpha: 1)
+        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
+            return
+        }
+        encoder.endEncoding()
+        let shared = shared
+        buffer.addCompletedHandler { buffer in
+            if buffer.status == .error || buffer.error != nil { shared.addError() }
+        }
+        buffer.present(drawable)
+        buffer.commit()
+    }
+}
+
+/// A view backed by a `CAMetalLayer`; its size goes to the render thread.
+private final class MetalView: UIView {
+    override class var layerClass: AnyClass { CAMetalLayer.self }
+
+    private let shared: RenderShared
+    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
+
+    init(shared: RenderShared) {
+        self.shared = shared
+        super.init(frame: .zero)
+    }
+
+    @available(*, unavailable)
+    required init?(coder: NSCoder) { fatalError("not used") }
+
+    override func didMoveToWindow() {
+        super.didMoveToWindow()
+        if let scale = window?.screen.scale { contentScaleFactor = scale }
+        setNeedsLayout()
+    }
+
+    override func layoutSubviews() {
+        super.layoutSubviews()
+        shared.drawableSize = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
+    }
+}
diff --git a/App/Strings/RouteStrings.swift b/App/Strings/RouteStrings.swift
index 3214a45..80adea3 100644
--- a/App/Strings/RouteStrings.swift
+++ b/App/Strings/RouteStrings.swift
@@ -26,6 +26,17 @@ enum RouteStrings {
         return RouteID(rawValue: raw).map(name) ?? raw
     }
 
+    /// The games a route serves, for the device screen's route table.
+    static func servesKey(_ route: RouteID) -> LocalizedStringKey {
+        switch route {
+        case .nativeKirikiri: "route.serves.native-kirikiri"
+        case .nativeRenPy: "route.serves.native-renpy"
+        case .wineFEX: "route.serves.wine-fex"
+        case .wineBox64: "route.serves.wine-box64"
+        case .linuxFEX: "route.serves.linux-fex"
+        }
+    }
+
     static func verdictKey(_ verdict: RouteVerdict) -> LocalizedStringKey {
         switch verdict {
         case .runnable: "route.verdict.runnable"
diff --git a/App/en.lproj/Localizable.strings b/App/en.lproj/Localizable.strings
index f2bc659..f11e4f4 100644
--- a/App/en.lproj/Localizable.strings
+++ b/App/en.lproj/Localizable.strings
@@ -331,3 +331,26 @@
 "import.space.detail" = "The copy needs %1$@, and the drive has %2$@ free.";
 "import.progress" = "%1$@ of %2$@";
 "import.copying.footer" = "Keep Eikon open until the copy finishes.";
+
+/* This device: routes, gates and developer tools */
+"status.section.routes" = "Routes";
+"status.section.gates" = "Device checks";
+"status.section.developer" = "Developer";
+"route.serves.native-kirikiri" = "Kirikiri games";
+"route.serves.native-renpy" = "Ren'Py games";
+"route.serves.wine-fex" = "Windows games (Unity, Kirikiri, GameMaker, BGI and others)";
+"route.serves.wine-box64" = "32-bit Windows games (Unity, Kirikiri, GameMaker, BGI and others)";
+"route.serves.linux-fex" = "Linux games";
+"developer.settingsForked" = "Settings from a newer version of Eikon were found and kept unchanged. Changes made in this version are stored separately.";
+"developer.runTestSession" = "Run test session";
+"developer.simulateCrash" = "Simulate crash during session";
+"developer.simulateCrash.footnote" = "Eikon quits about 5 seconds after the session starts. A crash report appears on the next launch.";
+"developer.testSession.failed" = "The test session couldn't start.";
+"developer.replicaID" = "Settings replica ID";
+"developer.gates" = "Gate store";
+"developer.gates.empty" = "Empty";
+"developer.gates.stamp" = "App %1$@ · iOS %2$@";
+"developer.gates.result.passed" = "passed";
+"developer.gates.result.failed" = "failed";
+"developer.gates.result.unmeasured" = "not measured";
+"developer.testPattern.errors" = "Command-buffer errors: %d";
