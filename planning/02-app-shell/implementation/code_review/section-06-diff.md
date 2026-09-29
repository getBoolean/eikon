diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/GateName.swift b/Packages/EikonCore/Sources/EikonCore/Routes/GateName.swift
new file mode 100644
index 0000000..7573763
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/GateName.swift
@@ -0,0 +1,14 @@
+/// A device capability measured at runtime. Open: later splits add gates, and the UI
+/// gives unknown ones a generic sentence with the raw name.
+public struct GateName: RawRepresentable, Hashable, Codable, Sendable {
+    public let rawValue: String
+
+    public init(rawValue: String) {
+        self.rawValue = rawValue
+    }
+
+    /// Guest code may use x18 (Apple reserves it).
+    public static let x18 = GateName(rawValue: "x18")
+    /// A 32-bit guest can open a window.
+    public static let guestWindow = GateName(rawValue: "guestWindow")
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/GateState.swift b/Packages/EikonCore/Sources/EikonCore/Routes/GateState.swift
new file mode 100644
index 0000000..cfa1dad
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/GateState.swift
@@ -0,0 +1,7 @@
+/// A gate's measured result. A missing entry means `unmeasured`.
+public enum GateState: Sendable, Equatable {
+    case passed
+    /// `stale`: it failed before an app or OS update and hasn't been re-checked since.
+    case failed(stale: Bool)
+    case unmeasured
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RouteID.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RouteID.swift
new file mode 100644
index 0000000..f6ccf20
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RouteID.swift
@@ -0,0 +1,5 @@
+/// How a game can run.
+public enum RouteID: String, Codable, Sendable, CaseIterable {
+    case nativeKirikiri = "native-kirikiri", nativeRenPy = "native-renpy"
+    case wineFEX = "wine-fex", wineBox64 = "wine-box64", linuxFEX = "linux-fex"
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RoutePicker.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RoutePicker.swift
new file mode 100644
index 0000000..687c867
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RoutePicker.swift
@@ -0,0 +1,82 @@
+/// Decides how a game would run. Pure: no I/O, no global state.
+public enum RoutePicker {
+    /// Non-native routes in preference order: Wine+FEX, then Box64 (demoted behind FEX),
+    /// then Linux+FEX.
+    private static let fallbackOrder: [RouteID] = [.wineFEX, .wineBox64, .linuxFEX]
+
+    /// Evaluates every route, orders them by preference, picks one, applies an override.
+    public static func decide(detection: DetectionResult, environment: RouteEnvironment,
+                              override: RouteID?) -> RouteDecision {
+        let native = RouteRules.nativeRoute(for: detection.engine)
+        let order = (native.map { [$0] } ?? []) + RouteID.allCases.filter { $0 != native && !fallbackOrder.contains($0) }
+            + fallbackOrder
+        var candidates = order.map { evaluate($0, detection: detection, environment: environment) }
+        for index in candidates.indices {
+            switch candidates[index].route {
+            case .wineFEX:
+                if native != nil { candidates[index].reasons.append(.nativeFirst) }
+            case .wineBox64:
+                if native != nil { candidates[index].reasons.append(.nativeFirst) }
+                if environment.jitUsable { candidates[index].reasons.append(.fexPreferredWithJIT) }
+            case .nativeKirikiri, .nativeRenPy, .linuxFEX:
+                break
+            }
+        }
+
+        if let override, let index = candidates.firstIndex(where: { $0.route == override }) {
+            var forced = candidates[index]
+            let warnings = forced.verdict.isRunnable ? [] : forced.reasons
+            forced.reasons.append(.overriddenByUser)
+            return RouteDecision(chosen: forced, candidates: candidates, isOverride: true, overrideWarnings: warnings)
+        }
+        let chosen = candidates.first { $0.verdict.isRunnable } ?? candidates.first { $0.verdict == .planned }
+        return RouteDecision(chosen: chosen, candidates: candidates, isOverride: false, overrideWarnings: [])
+    }
+
+    /// The verdict comes from the first rule that applies: target, JIT, failed gates,
+    /// not built, runtime declined, then runnable (with warnings for unmeasured gates).
+    static func evaluate(_ route: RouteID, detection: DetectionResult, environment: RouteEnvironment) -> RouteCandidate {
+        guard let rule = RouteRules.table[route] else {
+            return RouteCandidate(route: route, verdict: .unavailable, reasons: [.notInThisBuild])
+        }
+        func unavailable(_ reasons: [RouteReason]) -> RouteCandidate {
+            RouteCandidate(route: route, verdict: .unavailable, reasons: reasons)
+        }
+
+        var architecture: CPUArchitecture?
+        switch rule.target {
+        case .engine(let engine):
+            guard detection.engine == engine else { return unavailable([.engineNotHandled(detection.engine)]) }
+        case .executable(let platform, let architectures):
+            guard let executable = detection.executables[platform] else {
+                switch platform {
+                case .windows: return unavailable([.needsWindowsBinary])
+                case .linux: return unavailable([.needsLinuxBinary])
+                }
+            }
+            guard architectures.contains(executable.architecture) else {
+                if route == .wineBox64, executable.architecture == .amd64 { return unavailable([.box64Only32Bit]) }
+                return unavailable([.architectureUnsupported(executable.architecture)])
+            }
+            architecture = executable.architecture
+        }
+
+        if rule.needsJIT, !environment.jitUsable { return unavailable([.needsJIT]) }
+
+        let gates = architecture.flatMap { rule.gates[$0] } ?? []
+        let failed = gates.compactMap { gate -> RouteReason? in
+            if case .failed(let stale) = environment.gates[gate] { return .gateFailed(gate, stale: stale) }
+            return nil
+        }
+        if !failed.isEmpty { return unavailable(failed) }
+
+        guard environment.builtRoutes.contains(route) else {
+            return RouteCandidate(route: route, verdict: .planned, reasons: [.notInThisBuild])
+        }
+        if case .declined(let code) = environment.runtimeChecks[route] { return unavailable([.runtimeDeclined(code)]) }
+
+        let unmeasured = gates.filter { (environment.gates[$0] ?? .unmeasured) == .unmeasured }
+        return RouteCandidate(route: route, verdict: unmeasured.isEmpty ? .runnable : .runnableWithWarnings,
+                              reasons: unmeasured.map { .gateUnmeasured($0) })
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RouteReason.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RouteReason.swift
new file mode 100644
index 0000000..25fcd8e
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RouteReason.swift
@@ -0,0 +1,18 @@
+/// Why a route has its verdict. Codes only; the app maps them to sentences.
+public enum RouteReason: Sendable, Equatable {
+    case engineNotHandled(Engine)
+    case needsWindowsBinary, needsLinuxBinary
+    case architectureUnsupported(CPUArchitecture)
+    case needsJIT
+    /// Without JIT, only 32-bit Windows games can run.
+    case box64Only32Bit
+    /// Box64 is demoted behind FEX when JIT is usable, but still runnable.
+    case fexPreferredWithJIT
+    case gateFailed(GateName, stale: Bool)
+    case gateUnmeasured(GateName)
+    case notInThisBuild
+    case runtimeDeclined(RuntimeDeclineCode)
+    /// A native route for this engine comes first.
+    case nativeFirst
+    case overriddenByUser
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RouteRules.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RouteRules.swift
new file mode 100644
index 0000000..d762908
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RouteRules.swift
@@ -0,0 +1,33 @@
+/// What each route needs, in one data-like table. Splits 05 and 07 may adjust it.
+enum RouteRules {
+    struct Rule: Sendable {
+        enum Target: Sendable {
+            /// A native engine runtime.
+            case engine(Engine)
+            /// A main executable of this platform with one of these architectures.
+            case executable(GamePlatform, Set<CPUArchitecture>)
+        }
+
+        let target: Target
+        let needsJIT: Bool
+        /// Required gates by the executable's architecture.
+        let gates: [CPUArchitecture: [GateName]]
+    }
+
+    static let table: [RouteID: Rule] = [
+        .nativeKirikiri: Rule(target: .engine(.kirikiri), needsJIT: false, gates: [:]),
+        .nativeRenPy: Rule(target: .engine(.renpy), needsJIT: false, gates: [:]),
+        .wineFEX: Rule(target: .executable(.windows, [.i386, .amd64]), needsJIT: true,
+                       gates: [.amd64: [.x18], .i386: [.x18, .guestWindow]]),
+        .wineBox64: Rule(target: .executable(.windows, [.i386]), needsJIT: false, gates: [.i386: [.x18, .guestWindow]]),
+        .linuxFEX: Rule(target: .executable(.linux, [.amd64]), needsJIT: true, gates: [:]),
+    ]
+
+    /// The engine's native route, if it has one.
+    static func nativeRoute(for engine: Engine) -> RouteID? {
+        table.first { _, rule in
+            if case .engine(let native) = rule.target { return native == engine }
+            return false
+        }?.key
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RouteVerdict.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RouteVerdict.swift
new file mode 100644
index 0000000..30011ad
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RouteVerdict.swift
@@ -0,0 +1,58 @@
+public enum RouteVerdict: Sendable, Equatable {
+    case runnable, runnableWithWarnings, planned, unavailable
+
+    /// Runnable, with or without warnings.
+    public var isRunnable: Bool {
+        switch self {
+        case .runnable, .runnableWithWarnings: true
+        case .planned, .unavailable: false
+        }
+    }
+}
+
+public struct RouteCandidate: Sendable, Equatable {
+    public var route: RouteID
+    public var verdict: RouteVerdict
+    public var reasons: [RouteReason]
+
+    public init(route: RouteID, verdict: RouteVerdict, reasons: [RouteReason]) {
+        self.route = route
+        self.verdict = verdict
+        self.reasons = reasons
+    }
+}
+
+public struct RouteDecision: Sendable, Equatable {
+    /// nil: the game is unavailable.
+    public var chosen: RouteCandidate?
+    /// Every route, in preference order.
+    public var candidates: [RouteCandidate]
+    public var isOverride: Bool
+    /// The forced route's reasons when it isn't runnable; empty otherwise.
+    public var overrideWarnings: [RouteReason]
+
+    public init(chosen: RouteCandidate?, candidates: [RouteCandidate], isOverride: Bool, overrideWarnings: [RouteReason]) {
+        self.chosen = chosen
+        self.candidates = candidates
+        self.isOverride = isOverride
+        self.overrideWarnings = overrideWarnings
+    }
+}
+
+/// The device and build, as the picker sees them.
+public struct RouteEnvironment: Sendable {
+    public var jitUsable: Bool
+    /// Missing means unmeasured.
+    public var gates: [GateName: GateState]
+    public var builtRoutes: Set<RouteID>
+    /// Per game, from built runtimes. Missing means ok (the check may still be running).
+    public var runtimeChecks: [RouteID: RuntimeCheck]
+
+    public init(jitUsable: Bool, gates: [GateName: GateState], builtRoutes: Set<RouteID>,
+                runtimeChecks: [RouteID: RuntimeCheck]) {
+        self.jitUsable = jitUsable
+        self.gates = gates
+        self.builtRoutes = builtRoutes
+        self.runtimeChecks = runtimeChecks
+    }
+}
diff --git a/Packages/EikonCore/Sources/EikonCore/Routes/RuntimeCheck.swift b/Packages/EikonCore/Sources/EikonCore/Routes/RuntimeCheck.swift
new file mode 100644
index 0000000..9c23551
--- /dev/null
+++ b/Packages/EikonCore/Sources/EikonCore/Routes/RuntimeCheck.swift
@@ -0,0 +1,15 @@
+/// Why a built runtime declined a game. Open: the runtime splits own the values, and the
+/// UI maps each to `route.decline.<raw>` with a generic fallback.
+public struct RuntimeDeclineCode: RawRepresentable, Hashable, Codable, Sendable {
+    public let rawValue: String
+
+    public init(rawValue: String) {
+        self.rawValue = rawValue
+    }
+}
+
+/// A built runtime's verdict on one game.
+public enum RuntimeCheck: Sendable, Equatable {
+    case ok
+    case declined(RuntimeDeclineCode)
+}
diff --git a/Packages/EikonCore/Tests/EikonCoreTests/RoutePickerTests.swift b/Packages/EikonCore/Tests/EikonCoreTests/RoutePickerTests.swift
new file mode 100644
index 0000000..97bb88c
--- /dev/null
+++ b/Packages/EikonCore/Tests/EikonCoreTests/RoutePickerTests.swift
@@ -0,0 +1,142 @@
+import Testing
+@testable import EikonCore
+
+// MARK: Helpers
+
+private func executable(_ architecture: CPUArchitecture, _ platform: GamePlatform) -> ExecutableInfo {
+    ExecutableInfo(path: platform == .windows ? "Game.exe" : "Game", format: platform == .windows ? .pe : .elf,
+                   architecture: architecture, machine: 0, isGUI: platform == .windows ? true : nil)
+}
+
+private func game(_ engine: Engine = .unknown, windows: CPUArchitecture? = nil, linux: CPUArchitecture? = nil) -> DetectionResult {
+    var executables: [GamePlatform: ExecutableInfo] = [:]
+    if let windows { executables[.windows] = executable(windows, .windows) }
+    if let linux { executables[.linux] = executable(linux, .linux) }
+    return DetectionResult(engine: engine, details: EngineDetails(), gameRoot: "", executables: executables,
+                           keyFile: nil, detectorVersion: GameDetector.version)
+}
+
+private let allGates: [GateName: GateState] = [.x18: .passed, .guestWindow: .passed]
+
+/// Everything built, all gates passed, all checks ok, unless a row says otherwise.
+private func env(jit: Bool = true, gates: [GateName: GateState] = allGates, built: Set<RouteID> = Set(RouteID.allCases),
+                 checks: [RouteID: RuntimeCheck] = [:]) -> RouteEnvironment {
+    RouteEnvironment(jitUsable: jit, gates: gates, builtRoutes: built, runtimeChecks: checks)
+}
+
+private let declined = RuntimeCheck.declined(RuntimeDeclineCode(rawValue: "fixture-decline"))
+
+private func candidate(_ decision: RouteDecision, _ route: RouteID) -> RouteCandidate? {
+    decision.candidates.first { $0.route == route }
+}
+
+// MARK: Chosen route
+
+private struct Row: Sendable, CustomTestStringConvertible {
+    let label: String
+    let detection: DetectionResult
+    let environment: RouteEnvironment
+    let chosen: RouteID?
+    var verdict: RouteVerdict? = nil
+    var testDescription: String { label }
+}
+
+private let rows: [Row] = [
+    Row(label: "kirikiri native first", detection: game(.kirikiri, windows: .i386), environment: env(),
+        chosen: .nativeKirikiri),
+    Row(label: "renpy native first", detection: game(.renpy, windows: .amd64), environment: env(), chosen: .nativeRenPy),
+    Row(label: "windows i386 with JIT", detection: game(windows: .i386), environment: env(), chosen: .wineFEX),
+    Row(label: "windows amd64 with JIT", detection: game(windows: .amd64), environment: env(), chosen: .wineFEX),
+    Row(label: "windows i386 without JIT", detection: game(windows: .i386), environment: env(jit: false),
+        chosen: .wineBox64),
+    Row(label: "box64 when fex declined", detection: game(windows: .i386), environment: env(checks: [.wineFEX: declined]),
+        chosen: .wineBox64),
+    Row(label: "box64 when fex not built", detection: game(windows: .i386),
+        environment: env(built: Set(RouteID.allCases).subtracting([.wineFEX])), chosen: .wineBox64),
+    Row(label: "nothing built chooses the preferred route as planned", detection: game(.kirikiri, windows: .i386),
+        environment: env(built: []), chosen: .nativeKirikiri, verdict: .planned),
+    Row(label: "linux amd64 with JIT", detection: game(linux: .amd64), environment: env(), chosen: .linuxFEX),
+    Row(label: "linux amd64 without JIT", detection: game(linux: .amd64), environment: env(jit: false), chosen: nil),
+]
+
+@Test(arguments: rows)
+private func pickerChoosesTheExpectedRoute(row: Row) {
+    let decision = RoutePicker.decide(detection: row.detection, environment: row.environment, override: nil)
+    #expect(decision.chosen?.route == row.chosen)
+    if let verdict = row.verdict { #expect(decision.chosen?.verdict == verdict) }
+}
+
+// MARK: Reasons
+
+@Test func declinedNativeRuntimeFallsThroughToWineWithNativeFirst() {
+    let decision = RoutePicker.decide(detection: game(.kirikiri, windows: .i386),
+                                      environment: env(checks: [.nativeKirikiri: declined]), override: nil)
+    #expect(decision.chosen?.route == .wineFEX)
+    #expect(decision.chosen?.reasons.contains(.nativeFirst) == true)
+}
+
+@Test func box64IsDemotedBehindFEXWithJIT() {
+    let decision = RoutePicker.decide(detection: game(windows: .i386),
+                                      environment: env(built: Set(RouteID.allCases).subtracting([.wineFEX])), override: nil)
+    #expect(decision.chosen?.route == .wineBox64)
+    #expect(decision.chosen?.reasons.contains(.fexPreferredWithJIT) == true)
+}
+
+@Test func amd64WithoutJITIsUnavailableForLackOfJIT() {
+    let decision = RoutePicker.decide(detection: game(windows: .amd64), environment: env(jit: false), override: nil)
+    #expect(decision.chosen == nil)
+    #expect(candidate(decision, .wineFEX)?.verdict == .unavailable)
+    #expect(candidate(decision, .wineFEX)?.reasons.contains(.needsJIT) == true)
+    #expect(candidate(decision, .wineBox64)?.reasons.contains(.box64Only32Bit) == true)
+}
+
+@Test(arguments: [[GateName.x18: GateState.unmeasured, .guestWindow: .passed], [.guestWindow: .passed]])
+func unmeasuredGateWarns(gates: [GateName: GateState]) {
+    let decision = RoutePicker.decide(detection: game(windows: .i386), environment: env(gates: gates), override: nil)
+    #expect(decision.chosen?.verdict == .runnableWithWarnings)
+    #expect(decision.chosen?.reasons.contains(.gateUnmeasured(.x18)) == true)
+}
+
+@Test(arguments: [false, true])
+func failedGateMakesTheRouteUnavailable(stale: Bool) {
+    let decision = RoutePicker.decide(detection: game(windows: .amd64),
+                                      environment: env(gates: [.x18: .failed(stale: stale)]), override: nil)
+    #expect(candidate(decision, .wineFEX)?.verdict == .unavailable)
+    #expect(candidate(decision, .wineFEX)?.reasons.contains(.gateFailed(.x18, stale: stale)) == true)
+    #expect(decision.chosen == nil)
+}
+
+// MARK: Override
+
+@Test func overrideToAnUnavailableRouteIsChosenWithWarnings() {
+    let decision = RoutePicker.decide(detection: game(windows: .amd64), environment: env(jit: false), override: .wineFEX)
+    #expect(decision.chosen?.route == .wineFEX)
+    #expect(decision.isOverride)
+    #expect(decision.overrideWarnings.contains(.needsJIT))
+    #expect(decision.chosen?.reasons.contains(.overriddenByUser) == true)
+}
+
+@Test func overrideToARunnableRouteHasNoWarnings() {
+    let decision = RoutePicker.decide(detection: game(windows: .i386), environment: env(), override: .wineBox64)
+    #expect(decision.chosen?.route == .wineBox64)
+    #expect(decision.isOverride)
+    #expect(decision.overrideWarnings.isEmpty)
+}
+
+// MARK: Platforms and architectures
+
+@Test func multiPlatformUnityListsBothFEXRoutes() {
+    let decision = RoutePicker.decide(detection: game(.unity, windows: .amd64, linux: .amd64), environment: env(),
+                                      override: nil)
+    #expect(candidate(decision, .wineFEX)?.verdict.isRunnable == true)
+    #expect(candidate(decision, .linuxFEX)?.verdict.isRunnable == true)
+}
+
+@Test(arguments: [CPUArchitecture.arm64, .other])
+func unsupportedPEArchitectureHasNoRunnableWineRoute(architecture: CPUArchitecture) {
+    let decision = RoutePicker.decide(detection: game(windows: architecture), environment: env(), override: nil)
+    for route in [RouteID.wineFEX, .wineBox64] {
+        #expect(candidate(decision, route)?.verdict.isRunnable == false)
+    }
+    #expect(decision.chosen == nil)
+}
