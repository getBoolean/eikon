import EikonCore
import EikonKit
import SwiftUI

/// One route as this device would run it, independent of any game.
struct RouteRow: Identifiable {
    var route: RouteID
    var verdict: RouteVerdict
    var reasons: [RouteReason]
    var id: RouteID { route }
}

struct GateRow: Identifiable {
    var name: GateName
    var state: GateState
    /// From the stored result still meaningful on this build, if any.
    var detail: String?
    var measuredAt: Date?
    var id: String { name.rawValue }
}

/// Each route's own candidate, judged against a synthetic game that exercises its full
/// rule set. In memory only: no files, no names.
enum DeviceRouteTable {
    static func rows(environment: RouteEnvironment) -> [RouteRow] {
        RouteID.allCases.compactMap { route in
            let decision = RoutePicker.decide(detection: detection(for: route), environment: environment, override: nil)
            guard let candidate = decision.candidates.first(where: { $0.route == route }) else { return nil }
            // Ordering reasons compare routes for a game; they don't say whether this one works.
            let reasons = candidate.reasons.filter { $0 != .nativeFirst && $0 != .fexPreferredWithJIT }
            return RouteRow(route: route, verdict: candidate.verdict, reasons: reasons)
        }
    }

    /// The x86 Windows routes get an i386 program, which needs every gate; Linux gets amd64.
    private static func detection(for route: RouteID) -> DetectionResult {
        let windows = ExecutableInfo(path: "Game.exe", format: .pe, architecture: .i386, machine: 0x14c, isGUI: true)
        let linux = ExecutableInfo(path: "Game", format: .elf, architecture: .amd64, machine: 62, isGUI: nil)
        let (engine, executables): (Engine, [GamePlatform: ExecutableInfo]) = switch route {
        case .nativeKirikiri: (.kirikiri, [.windows: windows])
        case .nativeRenPy: (.renpy, [.windows: windows])
        case .wineFEX, .wineBox64: (.unknown, [.windows: windows])
        case .linuxFEX: (.unknown, [.linux: linux])
        }
        return DetectionResult(engine: engine, details: EngineDetails(), gameRoot: "", executables: executables,
                               keyFile: nil, detectorVersion: GameDetector.version)
    }

    /// The known gates first, then any other the store has, by name.
    static func gateRows(states: [GateName: GateState], current: [String: GateResult]) -> [GateRow] {
        let known: [GateName] = [.x18, .guestWindow]
        let others = states.keys.filter { !known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return (known + others).map { name in
            let result = current[name.rawValue]
            return GateRow(name: name, state: states[name] ?? .unmeasured, detail: result?.detail,
                           measuredAt: result?.measuredAt)
        }
    }
}

struct RouteTableSection: View {
    let routes: [RouteRow]
    let jitReason: JITReasonCode?

    var body: some View {
        Section(header: Text("status.section.routes")) {
            ForEach(routes) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(RouteStrings.name(row.route))
                        Spacer()
                        Text(RouteStrings.verdictKey(row.verdict))
                            .foregroundColor(row.verdict.isRunnable ? .green : .secondary)
                    }
                    Text(RouteStrings.servesKey(row.route))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(row.reasons.indices, id: \.self) { index in
                        Text(RouteStrings.reasonText(row.reasons[index], jitReason: jitReason))
                            .font(.footnote)
                    }
                }
            }
        }
    }
}

struct GateTableSection: View {
    let gates: [GateRow]

    var body: some View {
        Section(header: Text("status.section.gates")) {
            ForEach(gates) { gate in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(GateStrings.name(gate.name))
                        Spacer()
                        Text(GateStrings.stateKey(gate.state))
                            .foregroundColor(.secondary)
                    }
                    if let line = detailLine(gate) {
                        Text(verbatim: line)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func detailLine(_ gate: GateRow) -> String? {
        let parts = [gate.detail, gate.measuredAt.map(Self.dateFormatter.string)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

#if DEBUG
struct RouteTableSection_Previews: PreviewProvider {
    /// Every verdict, and every reason a device row can show.
    static let routes: [RouteRow] = [
        RouteRow(route: .nativeKirikiri, verdict: .runnable, reasons: []),
        RouteRow(route: .nativeRenPy, verdict: .planned, reasons: [.notInThisBuild]),
        RouteRow(route: .wineFEX, verdict: .unavailable, reasons: [.needsJIT]),
        RouteRow(route: .wineBox64, verdict: .runnableWithWarnings,
                 reasons: [.gateUnmeasured(.x18), .gateUnmeasured(.guestWindow), .fexPreferredWithJIT]),
        RouteRow(route: .linuxFEX, verdict: .unavailable,
                 reasons: [.gateFailed(.x18, stale: true), .gateFailed(.guestWindow, stale: false)]),
    ]

    static let states: [GateState] = [.passed, .failed(stale: false), .failed(stale: true), .unmeasured]

    /// Both known gates in one state, plus an unknown gate.
    static func gates(_ state: GateState) -> [GateRow] {
        [GateName.x18, .guestWindow, GateName(rawValue: "futureGate")].map {
            GateRow(name: $0, state: state, detail: state == .unmeasured ? nil : "sample detail",
                    measuredAt: state == .unmeasured ? nil : Date())
        }
    }

    static var previews: some View {
        List {
            RouteTableSection(routes: routes, jitReason: .sideloadedNoJIT)
            ForEach(states.indices, id: \.self) { GateTableSection(gates: gates(states[$0])) }
        }
        .listStyle(.insetGrouped)
    }
}
#endif
