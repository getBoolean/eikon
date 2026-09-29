public enum RouteVerdict: Sendable, Equatable {
    case runnable, runnableWithWarnings, planned, unavailable

    /// Runnable, with or without warnings.
    public var isRunnable: Bool {
        switch self {
        case .runnable, .runnableWithWarnings: true
        case .planned, .unavailable: false
        }
    }
}

public struct RouteCandidate: Sendable, Equatable {
    public var route: RouteID
    public var verdict: RouteVerdict
    public var reasons: [RouteReason]

    public init(route: RouteID, verdict: RouteVerdict, reasons: [RouteReason]) {
        self.route = route
        self.verdict = verdict
        self.reasons = reasons
    }
}

public struct RouteDecision: Sendable, Equatable {
    /// nil: the game is unavailable.
    public var chosen: RouteCandidate?
    /// Every route, in preference order.
    public var candidates: [RouteCandidate]
    public var isOverride: Bool
    /// The forced route's reasons when it isn't runnable; empty otherwise.
    public var overrideWarnings: [RouteReason]

    public init(chosen: RouteCandidate?, candidates: [RouteCandidate], isOverride: Bool, overrideWarnings: [RouteReason]) {
        self.chosen = chosen
        self.candidates = candidates
        self.isOverride = isOverride
        self.overrideWarnings = overrideWarnings
    }
}

/// The device and build, as the picker sees them.
public struct RouteEnvironment: Sendable {
    public var jitUsable: Bool
    /// Missing means unmeasured.
    public var gates: [GateName: GateState]
    public var builtRoutes: Set<RouteID>
    /// Per game, from built runtimes. Missing means ok (the check may still be running).
    public var runtimeChecks: [RouteID: RuntimeCheck]

    public init(jitUsable: Bool, gates: [GateName: GateState], builtRoutes: Set<RouteID>,
                runtimeChecks: [RouteID: RuntimeCheck]) {
        self.jitUsable = jitUsable
        self.gates = gates
        self.builtRoutes = builtRoutes
        self.runtimeChecks = runtimeChecks
    }
}
