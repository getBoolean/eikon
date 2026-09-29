import Testing
@testable import EikonCore

// MARK: Helpers

private func executable(_ architecture: CPUArchitecture, _ platform: GamePlatform) -> ExecutableInfo {
    ExecutableInfo(path: platform == .windows ? "Game.exe" : "Game", format: platform == .windows ? .pe : .elf,
                   architecture: architecture, machine: 0, isGUI: platform == .windows ? true : nil)
}

private func game(_ engine: Engine = .unknown, windows: CPUArchitecture? = nil, linux: CPUArchitecture? = nil) -> DetectionResult {
    var executables: [GamePlatform: ExecutableInfo] = [:]
    if let windows { executables[.windows] = executable(windows, .windows) }
    if let linux { executables[.linux] = executable(linux, .linux) }
    return DetectionResult(engine: engine, details: EngineDetails(), gameRoot: "", executables: executables,
                           keyFile: nil, detectorVersion: GameDetector.version)
}

private let allGates: [GateName: GateState] = [.x18: .passed, .guestWindow: .passed]

/// Everything built, all gates passed, all checks ok, unless a row says otherwise.
private func env(jit: Bool = true, gates: [GateName: GateState] = allGates, built: Set<RouteID> = Set(RouteID.allCases),
                 checks: [RouteID: RuntimeCheck] = [:]) -> RouteEnvironment {
    RouteEnvironment(jitUsable: jit, gates: gates, builtRoutes: built, runtimeChecks: checks)
}

private let declined = RuntimeCheck.declined(RuntimeDeclineCode(rawValue: "fixture-decline"))

private func candidate(_ decision: RouteDecision, _ route: RouteID) -> RouteCandidate? {
    decision.candidates.first { $0.route == route }
}

// MARK: Chosen route

private struct Row: Sendable, CustomTestStringConvertible {
    let label: String
    let detection: DetectionResult
    let environment: RouteEnvironment
    let chosen: RouteID?
    var verdict: RouteVerdict? = nil
    var testDescription: String { label }
}

private let rows: [Row] = [
    Row(label: "kirikiri native first", detection: game(.kirikiri, windows: .i386), environment: env(),
        chosen: .nativeKirikiri),
    Row(label: "renpy native first", detection: game(.renpy, windows: .amd64), environment: env(), chosen: .nativeRenPy),
    Row(label: "windows i386 with JIT", detection: game(windows: .i386), environment: env(), chosen: .wineFEX),
    Row(label: "windows amd64 with JIT", detection: game(windows: .amd64), environment: env(), chosen: .wineFEX),
    Row(label: "windows i386 without JIT", detection: game(windows: .i386), environment: env(jit: false),
        chosen: .wineBox64),
    Row(label: "box64 when fex declined", detection: game(windows: .i386), environment: env(checks: [.wineFEX: declined]),
        chosen: .wineBox64),
    Row(label: "box64 when fex not built", detection: game(windows: .i386),
        environment: env(built: Set(RouteID.allCases).subtracting([.wineFEX])), chosen: .wineBox64),
    Row(label: "nothing built chooses the preferred route as planned", detection: game(.kirikiri, windows: .i386),
        environment: env(built: []), chosen: .nativeKirikiri, verdict: .planned),
    Row(label: "a planned route never consults its runtime check", detection: game(windows: .i386),
        environment: env(jit: false, built: [], checks: [.wineBox64: declined]), chosen: .wineBox64, verdict: .planned),
    Row(label: "linux amd64 with JIT", detection: game(linux: .amd64), environment: env(), chosen: .linuxFEX),
    Row(label: "linux amd64 without JIT", detection: game(linux: .amd64), environment: env(jit: false), chosen: nil),
]

@Test(arguments: rows)
private func pickerChoosesTheExpectedRoute(row: Row) {
    let decision = RoutePicker.decide(detection: row.detection, environment: row.environment, override: nil)
    #expect(decision.chosen?.route == row.chosen)
    if let verdict = row.verdict { #expect(decision.chosen?.verdict == verdict) }
}

// MARK: Reasons

@Test func declinedNativeRuntimeFallsThroughToWineWithNativeFirst() {
    let decision = RoutePicker.decide(detection: game(.kirikiri, windows: .i386),
                                      environment: env(checks: [.nativeKirikiri: declined]), override: nil)
    #expect(decision.chosen?.route == .wineFEX)
    #expect(decision.chosen?.reasons.contains(.nativeFirst) == true)
}

@Test func box64IsDemotedBehindFEXWithJIT() {
    let decision = RoutePicker.decide(detection: game(windows: .i386),
                                      environment: env(built: Set(RouteID.allCases).subtracting([.wineFEX])), override: nil)
    #expect(decision.chosen?.route == .wineBox64)
    #expect(decision.chosen?.reasons.contains(.fexPreferredWithJIT) == true)
}

@Test func amd64WithoutJITIsUnavailableForLackOfJIT() {
    let decision = RoutePicker.decide(detection: game(windows: .amd64), environment: env(jit: false), override: nil)
    #expect(decision.chosen == nil)
    #expect(candidate(decision, .wineFEX)?.verdict == .unavailable)
    #expect(candidate(decision, .wineFEX)?.reasons.contains(.needsJIT) == true)
    #expect(candidate(decision, .wineBox64)?.reasons.contains(.box64Only32Bit) == true)
}

@Test(arguments: [[GateName.x18: GateState.unmeasured, .guestWindow: .passed], [.guestWindow: .passed]])
func unmeasuredGateWarns(gates: [GateName: GateState]) {
    let decision = RoutePicker.decide(detection: game(windows: .i386), environment: env(gates: gates), override: nil)
    #expect(decision.chosen?.verdict == .runnableWithWarnings)
    #expect(decision.chosen?.reasons.contains(.gateUnmeasured(.x18)) == true)
}

@Test(arguments: [false, true])
func failedGateMakesTheRouteUnavailable(stale: Bool) {
    let decision = RoutePicker.decide(detection: game(windows: .amd64),
                                      environment: env(gates: [.x18: .failed(stale: stale)]), override: nil)
    #expect(candidate(decision, .wineFEX)?.verdict == .unavailable)
    #expect(candidate(decision, .wineFEX)?.reasons.contains(.gateFailed(.x18, stale: stale)) == true)
    #expect(decision.chosen == nil)
}

// MARK: Override

@Test func overrideToAnUnavailableRouteIsChosenWithWarnings() {
    let decision = RoutePicker.decide(detection: game(windows: .amd64), environment: env(jit: false), override: .wineFEX)
    #expect(decision.chosen?.route == .wineFEX)
    #expect(decision.isOverride)
    #expect(decision.overrideWarnings.contains(.needsJIT))
    #expect(decision.chosen?.reasons.contains(.overriddenByUser) == true)
}

@Test func overrideToARunnableRouteHasNoWarnings() {
    let decision = RoutePicker.decide(detection: game(windows: .i386), environment: env(), override: .wineBox64)
    #expect(decision.chosen?.route == .wineBox64)
    #expect(decision.isOverride)
    #expect(decision.overrideWarnings.isEmpty)
}

// MARK: Platforms and architectures

@Test func multiPlatformUnityListsBothFEXRoutes() {
    let decision = RoutePicker.decide(detection: game(.unity, windows: .amd64, linux: .amd64), environment: env(),
                                      override: nil)
    #expect(candidate(decision, .wineFEX)?.verdict.isRunnable == true)
    #expect(candidate(decision, .linuxFEX)?.verdict.isRunnable == true)
}

@Test(arguments: [CPUArchitecture.arm64, .other])
func unsupportedPEArchitectureHasNoRunnableWineRoute(architecture: CPUArchitecture) {
    let decision = RoutePicker.decide(detection: game(windows: architecture), environment: env(), override: nil)
    for route in [RouteID.wineFEX, .wineBox64] {
        #expect(candidate(decision, route)?.verdict.isRunnable == false)
    }
    #expect(decision.chosen == nil)
}
