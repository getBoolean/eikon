diff --git a/App/Info.plist b/App/Info.plist
index 2c8d8c3..a1df55f 100644
--- a/App/Info.plist
+++ b/App/Info.plist
@@ -22,6 +22,8 @@
 	<string>$(CURRENT_PROJECT_VERSION)</string>
 	<key>EKGitCommit</key>
 	<string>$(EIKON_GIT_COMMIT)</string>
+	<key>EKRepositoryURL</key>
+	<string>https://github.com/getBoolean/eikon</string>
 	<key>EKPackageKind</key>
 	<string>development</string>
 	<key>LSRequiresIPhoneOS</key>
diff --git a/Packages/EikonKit/Package.swift b/Packages/EikonKit/Package.swift
index b5b3600..4352195 100644
--- a/Packages/EikonKit/Package.swift
+++ b/Packages/EikonKit/Package.swift
@@ -17,7 +17,11 @@ let package = Package(
             .product(name: "EikonCore", package: "EikonCore"),
             .product(name: "CEikonSession", package: "EikonCore"),
         ]),
-        .testTarget(name: "EikonKitTests", dependencies: ["EikonKit", "CEikonJIT"]),
+        .testTarget(name: "EikonKitTests", dependencies: [
+            "EikonKit",
+            "CEikonJIT",
+            .product(name: "CEikonSession", package: "EikonCore"),
+        ]),
     ],
     swiftLanguageModes: [.v6]
 )
diff --git a/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift b/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift
new file mode 100644
index 0000000..fd486e4
--- /dev/null
+++ b/Packages/EikonKit/Sources/EikonKit/Diagnostics/CrashReportController.swift
@@ -0,0 +1,140 @@
+import EikonCore
+import Foundation
+
+/// Everything the crash banner needs. Built fresh; never persisted.
+public struct CrashBanner: Identifiable, Equatable, Sendable {
+    /// The session id.
+    public var id: UUID
+    public var entry: CrashEntry
+    public var outcome: SessionOutcome
+    /// On screen only; nil for test sessions.
+    public var gameName: String?
+    /// A `RouteID` raw value, or `SessionRecord.testRoute`.
+    public var route: String
+    public var startedAt: Date
+    /// Offered as "Try <route> next time" only when non-nil.
+    public var alternative: RouteID?
+}
+
+/// Turns the previous launch's unfinished session into a history entry and, when the
+/// outcome warrants one, a banner with its actions. Every side effect goes through
+/// `Dependencies`, which the app fills with the live objects.
+@MainActor
+public final class CrashReportController: ObservableObject {
+    /// The pending banner, or nil.
+    @Published public private(set) var banner: CrashBanner?
+    /// Set after a report whose URL dropped breadcrumbs: the UI tells the user to paste the
+    /// device report from the clipboard into the issue.
+    @Published public private(set) var clipboardNotice = false
+
+    public struct Dependencies {
+        public var sentinel: SessionSentinel
+        public var history: CrashHistory
+        /// `EKRepositoryURL`.
+        public var repository: URL
+        /// nil when the game no longer exists.
+        public var routeDecision: @MainActor (GameID) -> RouteDecision?
+        /// On screen only.
+        public var displayName: @MainActor (GameID) -> String?
+        public var setRouteOverride: @MainActor (GameID, RouteID) -> Void
+        /// Includes `GateStore.current()`.
+        public var deviceReport: @MainActor () -> DeviceReport
+        public var openURL: @MainActor (URL) -> Void
+        public var copyToPasteboard: @MainActor (DeviceReport) -> Void
+        public var now: () -> Date
+
+        public init(sentinel: SessionSentinel, history: CrashHistory, repository: URL,
+                    routeDecision: @escaping @MainActor (GameID) -> RouteDecision?,
+                    displayName: @escaping @MainActor (GameID) -> String?,
+                    setRouteOverride: @escaping @MainActor (GameID, RouteID) -> Void,
+                    deviceReport: @escaping @MainActor () -> DeviceReport,
+                    openURL: @escaping @MainActor (URL) -> Void,
+                    copyToPasteboard: @escaping @MainActor (DeviceReport) -> Void,
+                    now: @escaping () -> Date = { Date() }) {
+            self.sentinel = sentinel
+            self.history = history
+            self.repository = repository
+            self.routeDecision = routeDecision
+            self.displayName = displayName
+            self.setRouteOverride = setRouteOverride
+            self.deviceReport = deviceReport
+            self.openURL = openURL
+            self.copyToPasteboard = copyToPasteboard
+            self.now = now
+        }
+    }
+
+    private let dependencies: Dependencies
+
+    /// Consumes the sentinel, snapshots the session into history (before any banner, so it
+    /// can still be reported after a dismiss), and publishes a banner if warranted. Call
+    /// before any session is armed: arming discards unconsumed evidence.
+    public init(dependencies: Dependencies) {
+        self.dependencies = dependencies
+        guard let consumed = dependencies.sentinel.consumeAtLaunch() else { return }
+        let entry = dependencies.history.add(consumed, now: dependencies.now())
+        guard entry.outcome.showsBanner else { return }
+        let record = entry.record
+        let isTest = record.route == SessionRecord.testRoute
+        banner = CrashBanner(id: entry.id, entry: entry, outcome: entry.outcome,
+                             gameName: isTest ? nil : dependencies.displayName(record.gameID),
+                             route: record.route, startedAt: record.startedAt,
+                             alternative: alternative(for: record))
+    }
+
+    /// Newest first, at most `CrashHistory.limitPerGame`, for the game detail screen.
+    public func history(for game: GameID, links: [GameID: GameID] = [:]) -> [CrashEntry] {
+        dependencies.history.entries(for: game, links: links)
+    }
+
+    /// Recomputes the banner's offer once the library has decisions (its first scan may
+    /// finish after launch). Call when the library publishes new decisions.
+    public func refreshAlternative() {
+        guard var current = banner else { return }
+        current.alternative = alternative(for: current.entry.record)
+        if current != banner { banner = current }
+    }
+
+    /// Writes the offered route as the game's override and clears the banner.
+    public func tryAlternative(_ banner: CrashBanner) {
+        guard let route = banner.alternative else { return }
+        dependencies.setRouteOverride(banner.entry.record.gameID, route)
+        if self.banner?.id == banner.id { self.banner = nil }
+    }
+
+    /// Opens a prefilled GitHub issue carrying codes and the report id only. When
+    /// breadcrumbs had to be dropped, the full device report goes to the clipboard.
+    public func report(_ entry: CrashEntry) {
+        let device = dependencies.deviceReport()
+        let built = CrashIssue.url(repository: dependencies.repository, entry: entry, device: Self.issueDevice(device),
+                                   reportID: CrashIssue.reportID(for: entry.record.gameID))
+        if built.droppedBreadcrumbs > 0 {
+            dependencies.copyToPasteboard(device)
+            clipboardNotice = true
+        }
+        dependencies.openURL(built.url)
+    }
+
+    /// History is untouched; the banner doesn't come back, since the sentinel is consumed.
+    public func dismiss() {
+        banner = nil
+        clipboardNotice = false
+    }
+
+    /// The first other candidate that can really run; never for test sessions or games
+    /// the library no longer knows.
+    private func alternative(for record: SessionRecord) -> RouteID? {
+        guard record.route != SessionRecord.testRoute, let decision = dependencies.routeDecision(record.gameID) else {
+            return nil
+        }
+        return decision.candidates.first { $0.route.rawValue != record.route && $0.verdict.isRunnable }?.route
+    }
+
+    static func issueDevice(_ report: DeviceReport) -> CrashIssue.Device {
+        CrashIssue.Device(appVersion: report.app.version, appBuild: report.app.build, appCommit: report.app.commit,
+                          modelIdentifier: report.device.modelIdentifier, osVersion: report.os.version,
+                          osBuild: report.os.build, installMethod: report.install.method.rawValue,
+                          jitUsable: report.jit.usable, jitSource: report.jit.source.rawValue,
+                          jitReasonCode: report.jit.reason?.rawValue)
+    }
+}
diff --git a/Packages/EikonKit/Tests/EikonKitTests/CrashReportControllerTests.swift b/Packages/EikonKit/Tests/EikonKitTests/CrashReportControllerTests.swift
new file mode 100644
index 0000000..e266a1d
--- /dev/null
+++ b/Packages/EikonKit/Tests/EikonKitTests/CrashReportControllerTests.swift
@@ -0,0 +1,147 @@
+import CEikonSession
+import EikonCore
+import Foundation
+import Testing
+@testable import EikonKit
+
+// MARK: Fakes
+
+/// Records what the controller asked the app to do.
+@MainActor
+private final class Effects {
+    var overrides: [(GameID, RouteID)] = []
+    var opened: [URL] = []
+    var copied = 0
+}
+
+private let crashedRoute = RouteID.nativeRenPy
+private let otherRoute = RouteID.wineFEX
+
+/// A session left armed by the "previous launch" in a temp directory.
+private func previousSession(phase: SessionRecord.Phase, route: String = crashedRoute.rawValue,
+                             game: GameID = .random(), breadcrumbs: Int = 0) throws -> SessionSentinel {
+    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
+    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
+    let sentinel = SessionSentinel(directory: directory)
+    try sentinel.arm(SessionRecord(gameID: game, engine: .renpy, architecture: nil, route: route, appBuild: "1",
+                                   startedAt: Date(timeIntervalSince1970: 1_800_000_000), phase: .running))
+    if phase != .running { try sentinel.setPhase(phase) }
+    if breadcrumbs > 0 {
+        // Straight to the file, not through the process-wide ring other tests may hold open.
+        FileManager.default.createFile(atPath: sentinel.breadcrumbsURL.path, contents: nil)
+        let fd = sentinel.breadcrumbsURL.path.withCString { open($0, O_WRONLY) }
+        defer { close(fd) }
+        for seq in 1...breadcrumbs {
+            _ = eikon_breadcrumb_write(fd, UInt64(seq), 1_800_000_000_000 + Int64(seq), 1, 0, 0)
+        }
+    }
+    return sentinel
+}
+
+private func decision(alternative verdict: RouteVerdict) -> RouteDecision {
+    let crashed = RouteCandidate(route: crashedRoute, verdict: .runnable, reasons: [])
+    let other = RouteCandidate(route: otherRoute, verdict: verdict, reasons: [])
+    return RouteDecision(chosen: crashed, candidates: [crashed, other], isOverride: false, overrideWarnings: [])
+}
+
+private func sampleReport() -> DeviceReport {
+    DeviceReport(
+        schemaVersion: DeviceReport.currentSchemaVersion, generatedAt: Date(),
+        app: AppInfo(version: "0.1.0", build: "1", commit: "abc", packageKind: "ipa", bundleIdentifier: "com.example"),
+        device: DeviceInfo(modelIdentifier: "iPad14,5", chip: "M2", cpuFamily: "0x0"),
+        os: OSInfo(name: "iPadOS", version: "17.0", build: "21A329"),
+        install: InstallInfo(method: .trollStore, evidence: InstallEvidence(bundlePath: "", homeDirectory: "", markers: [])),
+        jit: .placeholder, memory: MemoryInfo(availableBytes: 0), gates: [:], notes: nil)
+}
+
+@MainActor
+private func controller(_ sentinel: SessionSentinel, effects: Effects, decision: RouteDecision? = decision(alternative: .runnable),
+                        repository: URL = URL(string: "https://github.com/example/eikon")!) -> CrashReportController {
+    CrashReportController(dependencies: .init(
+        sentinel: sentinel, history: CrashHistory(directory: sentinel.directory), repository: repository,
+        routeDecision: { _ in decision }, displayName: { _ in "Shown Only On Screen" },
+        setRouteOverride: { effects.overrides.append(($0, $1)) }, deviceReport: sampleReport,
+        openURL: { effects.opened.append($0) }, copyToPasteboard: { _ in effects.copied += 1 }))
+}
+
+// MARK: Tests
+
+@MainActor @Suite struct CrashReportControllerTests {
+    /// A session left running publishes a banner for that game and route, keeps a history
+    /// entry, and reports with the report id and never the display name.
+    @Test func highSeveritySessionPublishesBanner() throws {
+        let game = GameID.random()
+        let sentinel = try previousSession(phase: .running, game: game)
+        let effects = Effects()
+        let crashes = controller(sentinel, effects: effects)
+
+        let banner = try #require(crashes.banner)
+        #expect(banner.entry.record.gameID == game)
+        #expect(banner.route == crashedRoute.rawValue)
+        #expect(crashes.history(for: game).count == 1)
+        #expect(!FileManager.default.fileExists(atPath: sentinel.sentinelURL.path))
+
+        crashes.report(banner.entry)
+        let url = try #require(effects.opened.first)
+        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
+        #expect(query.first { $0.name == "game" }?.value == CrashIssue.reportID(for: game))
+        #expect(!url.absoluteString.removingPercentEncoding!.contains("Shown Only On Screen"))
+    }
+
+    @Test func backgroundKillAddsHistoryWithoutBanner() throws {
+        let game = GameID.random()
+        let crashes = controller(try previousSession(phase: .background, game: game), effects: Effects())
+        #expect(crashes.banner == nil)
+        #expect(crashes.history(for: game).count == 1)
+    }
+
+    struct Row: Sendable, CustomTestStringConvertible {
+        var verdict: RouteVerdict
+        var route: String
+        var gameExists: Bool
+        var offered: Bool
+        var testDescription: String { "\(verdict) \(route) exists=\(gameExists) → \(offered)" }
+    }
+
+    @Test(arguments: [
+        Row(verdict: .runnable, route: crashedRoute.rawValue, gameExists: true, offered: true),
+        Row(verdict: .runnableWithWarnings, route: crashedRoute.rawValue, gameExists: true, offered: true),
+        Row(verdict: .planned, route: crashedRoute.rawValue, gameExists: true, offered: false),
+        Row(verdict: .unavailable, route: crashedRoute.rawValue, gameExists: true, offered: false),
+        Row(verdict: .runnable, route: SessionRecord.testRoute, gameExists: true, offered: false),
+        Row(verdict: .runnable, route: crashedRoute.rawValue, gameExists: false, offered: false),
+    ])
+    func tryAnotherRouteOfferedOnlyWhenRunnable(_ row: Row) throws {
+        let game = GameID.random()
+        let effects = Effects()
+        let crashes = controller(try previousSession(phase: .running, route: row.route, game: game), effects: effects,
+                                 decision: row.gameExists ? decision(alternative: row.verdict) : nil)
+        let banner = try #require(crashes.banner)
+        #expect((banner.alternative != nil) == row.offered)
+
+        crashes.tryAlternative(banner)
+        if row.offered {
+            #expect(effects.overrides.map(\.0) == [game])
+            #expect(effects.overrides.map(\.1) == [otherRoute])
+            #expect(crashes.banner == nil)
+        } else {
+            #expect(effects.overrides.isEmpty)
+        }
+    }
+
+    /// When the issue URL has no room for every breadcrumb, the full device report goes to
+    /// the clipboard and the controller says so.
+    @Test func droppedBreadcrumbsFallBackToTheClipboard() throws {
+        let effects = Effects()
+        let longRepository = URL(string: "https://github.com/example/" + String(repeating: "r", count: CrashIssue.maxURLLength))!
+        let crashes = controller(try previousSession(phase: .running, breadcrumbs: 3), effects: effects,
+                                 repository: longRepository)
+        let banner = try #require(crashes.banner)
+        #expect(!crashes.clipboardNotice)
+
+        crashes.report(banner.entry)
+        #expect(effects.copied == 1)
+        #expect(crashes.clipboardNotice)
+        #expect(effects.opened.count == 1)
+    }
+}
