import EikonCore
import Foundation

/// Everything the crash banner needs. Built fresh; never persisted.
public struct CrashBanner: Identifiable, Equatable, Sendable {
    /// The session id.
    public var id: UUID
    public var entry: CrashEntry
    public var outcome: SessionOutcome
    /// On screen only; nil for test sessions.
    public var gameName: String?
    /// A `RouteID` raw value, or `SessionRecord.testRoute`.
    public var route: String
    public var startedAt: Date
    /// Offered as "Try <route> next time" only when non-nil.
    public var alternative: RouteID?

    public init(id: UUID, entry: CrashEntry, outcome: SessionOutcome, gameName: String?, route: String, startedAt: Date,
                alternative: RouteID?) {
        self.id = id
        self.entry = entry
        self.outcome = outcome
        self.gameName = gameName
        self.route = route
        self.startedAt = startedAt
        self.alternative = alternative
    }
}

/// Turns the previous launch's unfinished session into a history entry and, when the
/// outcome warrants one, a banner with its actions. Every side effect goes through
/// `Dependencies`, which the app fills with the live objects.
@MainActor
public final class CrashReportController: ObservableObject {
    /// The pending banner, or nil.
    @Published public private(set) var banner: CrashBanner?
    /// Set after a report whose URL dropped breadcrumbs: the UI tells the user to paste the
    /// device report from the clipboard into the issue.
    @Published public private(set) var clipboardNotice = false

    public struct Dependencies {
        public var sentinel: SessionSentinel
        public var history: CrashHistory
        /// `EKRepositoryURL`.
        public var repository: URL
        /// nil when the game no longer exists.
        public var routeDecision: @MainActor (GameID) -> RouteDecision?
        /// On screen only.
        public var displayName: @MainActor (GameID) -> String?
        public var setRouteOverride: @MainActor (GameID, RouteID) -> Void
        /// Includes `GateStore.current()`.
        public var deviceReport: @MainActor () -> DeviceReport
        public var openURL: @MainActor (URL) -> Void
        public var copyToPasteboard: @MainActor (DeviceReport) -> Void
        public var now: @MainActor () -> Date

        public init(sentinel: SessionSentinel, history: CrashHistory, repository: URL,
                    routeDecision: @escaping @MainActor (GameID) -> RouteDecision?,
                    displayName: @escaping @MainActor (GameID) -> String?,
                    setRouteOverride: @escaping @MainActor (GameID, RouteID) -> Void,
                    deviceReport: @escaping @MainActor () -> DeviceReport,
                    openURL: @escaping @MainActor (URL) -> Void,
                    copyToPasteboard: @escaping @MainActor (DeviceReport) -> Void,
                    now: @escaping @MainActor () -> Date = { Date() }) {
            self.sentinel = sentinel
            self.history = history
            self.repository = repository
            self.routeDecision = routeDecision
            self.displayName = displayName
            self.setRouteOverride = setRouteOverride
            self.deviceReport = deviceReport
            self.openURL = openURL
            self.copyToPasteboard = copyToPasteboard
            self.now = now
        }
    }

    private let dependencies: Dependencies

    /// Consumes the sentinel, snapshots the session into history (before any banner, so it
    /// can still be reported after a dismiss), and publishes a banner if warranted. Call
    /// before any session is armed: arming discards unconsumed evidence.
    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        guard let consumed = dependencies.sentinel.consumeAtLaunch() else { return }
        let entry = dependencies.history.add(consumed, now: dependencies.now())
        guard entry.outcome.showsBanner else { return }
        let record = entry.record
        let isTest = record.route == SessionRecord.testRoute
        banner = CrashBanner(id: entry.id, entry: entry, outcome: entry.outcome,
                             gameName: isTest ? nil : dependencies.displayName(record.gameID),
                             route: record.route, startedAt: record.startedAt,
                             alternative: alternative(for: record))
    }

    /// Newest first, at most `CrashHistory.limitPerGame`, for the game detail screen.
    public func history(for game: GameID, links: [GameID: GameID] = [:]) -> [CrashEntry] {
        dependencies.history.entries(for: game, links: links)
    }

    /// Recomputes the banner's offer once the library has decisions (its first scan may
    /// finish after launch). Call when the library publishes settled decisions, not on
    /// every intermediate change, or the offer flickers during a rescan.
    public func refreshAlternative() {
        guard var current = banner else { return }
        current.alternative = alternative(for: current.entry.record)
        if current != banner { banner = current }
    }

    /// Writes the offered route as the game's override and clears the banner. The offer is
    /// checked again, since a view may hold an older copy of the banner.
    public func tryAlternative(_ banner: CrashBanner) {
        let current = self.banner?.id == banner.id ? self.banner?.alternative : alternative(for: banner.entry.record)
        guard let route = current else { return }
        dependencies.setRouteOverride(banner.entry.record.gameID, route)
        if self.banner?.id == banner.id { self.banner = nil }
    }

    /// Opens a prefilled GitHub issue with codes, the report id and the game's display name.
    /// The user reviews it in Safari and chooses to submit, so the name is shared by
    /// consent; it goes nowhere else. When breadcrumbs had to be dropped, the full device
    /// report goes to the clipboard.
    public func report(_ entry: CrashEntry) {
        let device = dependencies.deviceReport()
        let record = entry.record
        let name = record.route == SessionRecord.testRoute ? nil : dependencies.displayName(record.gameID)
        let built = CrashIssue.url(repository: dependencies.repository, entry: entry, device: Self.issueDevice(device),
                                   reportID: CrashIssue.reportID(for: record.gameID), gameName: name)
        if built.droppedBreadcrumbs > 0 {
            dependencies.copyToPasteboard(device)
        }
        // About this report only: an earlier report's clipboard may be long gone.
        clipboardNotice = built.droppedBreadcrumbs > 0
        dependencies.openURL(built.url)
    }

    /// The user has seen the clipboard notice; the banner stays.
    public func acknowledgeClipboardNotice() {
        clipboardNotice = false
    }

    /// History is untouched; the banner doesn't come back, since the sentinel is consumed.
    public func dismiss() {
        banner = nil
        clipboardNotice = false
    }

    /// The first other candidate that can really run; never for test sessions or games
    /// the library no longer knows.
    private func alternative(for record: SessionRecord) -> RouteID? {
        guard record.route != SessionRecord.testRoute, let decision = dependencies.routeDecision(record.gameID) else {
            return nil
        }
        return decision.candidates.first { $0.route.rawValue != record.route && $0.verdict.isRunnable }?.route
    }

    static func issueDevice(_ report: DeviceReport) -> CrashIssue.Device {
        CrashIssue.Device(appVersion: report.app.version, appBuild: report.app.build, appCommit: report.app.commit,
                          modelIdentifier: report.device.modelIdentifier, osVersion: report.os.version,
                          osBuild: report.os.build, installMethod: report.install.method.rawValue,
                          jitUsable: report.jit.usable, jitSource: report.jit.source.rawValue,
                          jitReasonCode: report.jit.reason?.rawValue)
    }
}
