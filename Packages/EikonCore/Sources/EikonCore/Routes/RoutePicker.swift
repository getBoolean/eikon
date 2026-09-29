/// Decides how a game would run. Pure: no I/O, no global state.
public enum RoutePicker {
    /// Non-native routes in preference order: Wine+FEX, then Box64 (demoted behind FEX),
    /// then Linux+FEX.
    private static let fallbackOrder: [RouteID] = [.wineFEX, .wineBox64, .linuxFEX]

    /// Evaluates every route, orders them by preference, picks one, applies an override.
    public static func decide(detection: DetectionResult, environment: RouteEnvironment,
                              override: RouteID?) -> RouteDecision {
        let native = RouteRules.nativeRoute(for: detection.engine)
        // Native first, then the fallbacks, then other engines' native routes (never runnable here).
        let order = (native.map { [$0] } ?? []) + fallbackOrder
            + RouteID.allCases.filter { $0 != native && !fallbackOrder.contains($0) }
        var candidates = order.map { evaluate($0, detection: detection, environment: environment) }
        // Ordering reasons only where the route could run; on an unavailable one they'd mislead.
        for index in candidates.indices where candidates[index].verdict != .unavailable {
            switch candidates[index].route {
            case .wineFEX:
                if native != nil { candidates[index].reasons.append(.nativeFirst) }
            case .wineBox64:
                if native != nil { candidates[index].reasons.append(.nativeFirst) }
                if environment.jitUsable { candidates[index].reasons.append(.fexPreferredWithJIT) }
            case .nativeKirikiri, .nativeRenPy, .linuxFEX:
                break
            }
        }

        if let override, let index = candidates.firstIndex(where: { $0.route == override }) {
            var forced = candidates[index]
            let warnings = forced.verdict.isRunnable ? [] : forced.reasons
            forced.reasons.append(.overriddenByUser)
            candidates[index] = forced
            return RouteDecision(chosen: forced, candidates: candidates, isOverride: true, overrideWarnings: warnings)
        }
        let chosen = candidates.first { $0.verdict.isRunnable } ?? candidates.first { $0.verdict == .planned }
        return RouteDecision(chosen: chosen, candidates: candidates, isOverride: false, overrideWarnings: [])
    }

    /// The verdict comes from the first rule that applies: target, JIT, failed gates,
    /// not built, runtime declined, then runnable (with warnings for unmeasured gates).
    static func evaluate(_ route: RouteID, detection: DetectionResult, environment: RouteEnvironment) -> RouteCandidate {
        let rule = RouteRules.rule(for: route)
        func unavailable(_ reasons: [RouteReason]) -> RouteCandidate {
            RouteCandidate(route: route, verdict: .unavailable, reasons: reasons)
        }

        var architecture: CPUArchitecture?
        switch rule.target {
        case .engine(let engine):
            guard detection.engine == engine else { return unavailable([.engineNotHandled(detection.engine)]) }
        case .executable(let platform, let architectures):
            guard let executable = detection.executables[platform] else {
                switch platform {
                case .windows: return unavailable([.needsWindowsBinary])
                case .linux: return unavailable([.needsLinuxBinary])
                }
            }
            guard architectures.contains(executable.architecture) else {
                if route == .wineBox64, executable.architecture == .amd64 { return unavailable([.box64Only32Bit]) }
                return unavailable([.architectureUnsupported(executable.architecture)])
            }
            architecture = executable.architecture
        }

        if rule.needsJIT, !environment.jitUsable { return unavailable([.needsJIT]) }

        let gates = rule.requiredGates(for: architecture)
        let failed = gates.compactMap { gate -> RouteReason? in
            if case .failed(let stale) = environment.gates[gate] { return .gateFailed(gate, stale: stale) }
            return nil
        }
        if !failed.isEmpty { return unavailable(failed) }

        guard environment.builtRoutes.contains(route) else {
            return RouteCandidate(route: route, verdict: .planned, reasons: [.notInThisBuild])
        }
        if case .declined(let code) = environment.runtimeChecks[route] { return unavailable([.runtimeDeclined(code)]) }

        let unmeasured = gates.filter { (environment.gates[$0] ?? .unmeasured) == .unmeasured }
        return RouteCandidate(route: route, verdict: unmeasured.isEmpty ? .runnable : .runnableWithWarnings,
                              reasons: unmeasured.map { .gateUnmeasured($0) })
    }
}
