import CEikonSession
import EikonCore
import Foundation
import Testing
@testable import EikonKit

// MARK: Fakes

/// Records what the controller asked the app to do.
@MainActor
private final class Effects {
    var overrides: [(GameID, RouteID)] = []
    var opened: [URL] = []
    var copied = 0
}

private let crashedRoute = RouteID.nativeRenPy
private let otherRoute = RouteID.wineFEX

/// A session left armed by the "previous launch" in a temp directory.
private func previousSession(phase: SessionRecord.Phase, route: String = crashedRoute.rawValue,
                             game: GameID = .random(), breadcrumbs: Int = 0) throws -> SessionSentinel {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sentinel = SessionSentinel(directory: directory)
    try sentinel.arm(SessionRecord(gameID: game, engine: .renpy, architecture: nil, route: route, appBuild: "1",
                                   startedAt: Date(timeIntervalSince1970: 1_800_000_000), phase: .running))
    if phase != .running { try sentinel.setPhase(phase) }
    if breadcrumbs > 0 {
        // Straight to the file, not through the process-wide ring other tests may hold open.
        FileManager.default.createFile(atPath: sentinel.breadcrumbsURL.path, contents: nil)
        let fd = sentinel.breadcrumbsURL.path.withCString { open($0, O_WRONLY) }
        defer { close(fd) }
        for seq in 1...breadcrumbs {
            _ = eikon_breadcrumb_write(fd, UInt64(seq), 1_800_000_000_000 + Int64(seq), 1, 0, 0)
        }
    }
    return sentinel
}

private func decision(alternative verdict: RouteVerdict) -> RouteDecision {
    let crashed = RouteCandidate(route: crashedRoute, verdict: .runnable, reasons: [])
    let other = RouteCandidate(route: otherRoute, verdict: verdict, reasons: [])
    return RouteDecision(chosen: crashed, candidates: [crashed, other], isOverride: false, overrideWarnings: [])
}

private func sampleReport() -> DeviceReport {
    DeviceReport(
        schemaVersion: DeviceReport.currentSchemaVersion, generatedAt: Date(),
        app: AppInfo(version: "0.1.0", build: "1", commit: "abc", packageKind: "ipa", bundleIdentifier: "com.example"),
        device: DeviceInfo(modelIdentifier: "iPad14,5", chip: "M2", cpuFamily: "0x0"),
        os: OSInfo(name: "iPadOS", version: "17.0", build: "21A329"),
        install: InstallInfo(method: .trollStore, evidence: InstallEvidence(bundlePath: "", homeDirectory: "", markers: [])),
        jit: .placeholder, memory: MemoryInfo(availableBytes: 0), gates: [:], notes: nil)
}

@MainActor
private func controller(_ sentinel: SessionSentinel, effects: Effects, decision: RouteDecision? = decision(alternative: .runnable),
                        repository: URL = URL(string: "https://github.com/example/eikon")!) -> CrashReportController {
    CrashReportController(dependencies: .init(
        sentinel: sentinel, history: CrashHistory(directory: sentinel.directory), repository: repository,
        routeDecision: { _ in decision }, displayName: { _ in "Shown Only On Screen" },
        setRouteOverride: { effects.overrides.append(($0, $1)) }, deviceReport: sampleReport,
        openURL: { effects.opened.append($0) }, copyToPasteboard: { _ in effects.copied += 1 }))
}

// MARK: Tests

@MainActor @Suite struct CrashReportControllerTests {
    /// A session left running publishes a banner for that game and route, keeps a history
    /// entry, and reports with the report id and never the display name.
    @Test func highSeveritySessionPublishesBanner() throws {
        let game = GameID.random()
        let sentinel = try previousSession(phase: .running, game: game)
        let effects = Effects()
        let crashes = controller(sentinel, effects: effects)

        let banner = try #require(crashes.banner)
        #expect(banner.entry.record.gameID == game)
        #expect(banner.route == crashedRoute.rawValue)
        #expect(crashes.history(for: game).count == 1)
        #expect(!FileManager.default.fileExists(atPath: sentinel.sentinelURL.path))

        crashes.report(banner.entry)
        let url = try #require(effects.opened.first)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "game" }?.value == CrashIssue.reportID(for: game))
        #expect(!url.absoluteString.removingPercentEncoding!.contains("Shown Only On Screen"))
    }

    @Test func backgroundKillAddsHistoryWithoutBanner() throws {
        let game = GameID.random()
        let crashes = controller(try previousSession(phase: .background, game: game), effects: Effects())
        #expect(crashes.banner == nil)
        #expect(crashes.history(for: game).count == 1)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var verdict: RouteVerdict
        var route: String
        var gameExists: Bool
        var offered: Bool
        var testDescription: String { "\(verdict) \(route) exists=\(gameExists) → \(offered)" }
    }

    @Test(arguments: [
        Row(verdict: .runnable, route: crashedRoute.rawValue, gameExists: true, offered: true),
        Row(verdict: .runnableWithWarnings, route: crashedRoute.rawValue, gameExists: true, offered: true),
        Row(verdict: .planned, route: crashedRoute.rawValue, gameExists: true, offered: false),
        Row(verdict: .unavailable, route: crashedRoute.rawValue, gameExists: true, offered: false),
        Row(verdict: .runnable, route: SessionRecord.testRoute, gameExists: true, offered: false),
        Row(verdict: .runnable, route: crashedRoute.rawValue, gameExists: false, offered: false),
    ])
    func tryAnotherRouteOfferedOnlyWhenRunnable(_ row: Row) throws {
        let game = GameID.random()
        let effects = Effects()
        let crashes = controller(try previousSession(phase: .running, route: row.route, game: game), effects: effects,
                                 decision: row.gameExists ? decision(alternative: row.verdict) : nil)
        let banner = try #require(crashes.banner)
        #expect((banner.alternative != nil) == row.offered)

        crashes.tryAlternative(banner)
        if row.offered {
            #expect(effects.overrides.map(\.0) == [game])
            #expect(effects.overrides.map(\.1) == [otherRoute])
            #expect(crashes.banner == nil)
        } else {
            #expect(effects.overrides.isEmpty)
        }
    }

    /// When the issue URL has no room for every breadcrumb, the full device report goes to
    /// the clipboard and the controller says so.
    @Test func droppedBreadcrumbsFallBackToTheClipboard() throws {
        let effects = Effects()
        // Longer than the limit on its own, so breadcrumbs are dropped whatever they hold.
        let longRepository = URL(string: "https://github.com/example/" + String(repeating: "r", count: CrashIssue.maxURLLength))!
        let crashes = controller(try previousSession(phase: .running, breadcrumbs: 3), effects: effects,
                                 repository: longRepository)
        let banner = try #require(crashes.banner)
        #expect(!crashes.clipboardNotice)

        crashes.report(banner.entry)
        #expect(effects.copied == 1)
        #expect(crashes.clipboardNotice)
        #expect(effects.opened.count == 1)
    }
}
