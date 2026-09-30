import EikonCore
import Foundation

/// What a runtime check result is cached under, per route: the game and its build (the
/// location's exact fingerprint signal), so a patch re-runs the check.
public struct RuntimeCheckKey: Hashable, Sendable {
    public var gameID: GameID
    public var build: Keyed

    public init(gameID: GameID, build: Keyed) {
        self.gameID = gameID
        self.build = build
    }
}

/// The runtimes this build has, and their cached game checks. Runtimes register in
/// `EikonApp.init`; split 02 registers none.
@MainActor
public final class RuntimeRegistry: ObservableObject {
    /// Feeds `RouteEnvironment.builtRoutes`.
    @Published public private(set) var builtRoutes: Set<RouteID> = []

    private struct CacheKey: Hashable {
        var route: RouteID
        var key: RuntimeCheckKey
    }

    private var types: [RouteID: any GameRuntime.Type] = [:]
    private var checkers: [RouteID: @Sendable (DetectionResult, URL) async -> RuntimeCheck] = [:]
    private var cache: [CacheKey: Task<RuntimeCheck, Never>] = [:]

    public init() {}

    /// Replaces any runtime for the same route and drops every cached check.
    public func register<T: GameRuntime>(_ type: T.Type) {
        types[T.route] = type
        checkers[T.route] = { detection, root in await T.check(detection, root: root) }
        cache.removeAll()
        builtRoutes.insert(T.route)
    }

    public func runtimeType(for route: RouteID) -> (any GameRuntime.Type)? {
        types[route]
    }

    /// Runs the route's check off the main actor, once per key; concurrent callers share it.
    /// Only built routes are checked: use `checks` rather than asking for others.
    public func check(route: RouteID, detection: DetectionResult, root: URL, cacheKey: RuntimeCheckKey) async -> RuntimeCheck {
        guard let task = checkTask(route: route, detection: detection, root: root, cacheKey: cacheKey) else {
            assertionFailure("no runtime registered for this route")
            return .ok
        }
        return await task.value
    }

    /// Every registered route's check, for `RouteEnvironment.runtimeChecks`. The checks
    /// run concurrently.
    public func checks(detection: DetectionResult, root: URL, cacheKey: RuntimeCheckKey) async -> [RouteID: RuntimeCheck] {
        let tasks = checkers.keys.compactMap { route in
            checkTask(route: route, detection: detection, root: root, cacheKey: cacheKey).map { (route, $0) }
        }
        var results: [RouteID: RuntimeCheck] = [:]
        for (route, task) in tasks {
            results[route] = await task.value
        }
        return results
    }

    private func checkTask(route: RouteID, detection: DetectionResult, root: URL,
                           cacheKey: RuntimeCheckKey) -> Task<RuntimeCheck, Never>? {
        guard let checker = checkers[route] else { return nil }
        let key = CacheKey(route: route, key: cacheKey)
        if let running = cache[key] { return running }
        let task = Task.detached { await checker(detection, root) }
        cache[key] = task
        return task
    }
}
