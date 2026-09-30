import EikonCore
import EikonKit
import SwiftUI

/// Route names, verdicts, reasons and runtime declines. Exhaustive: a new case fails the
/// build until it has a key.
enum RouteStrings {
    static func nameKey(_ route: RouteID) -> String {
        switch route {
        case .nativeKirikiri: "route.id.native-kirikiri"
        case .nativeRenPy: "route.id.native-renpy"
        case .wineFEX: "route.id.wine-fex"
        case .wineBox64: "route.id.wine-box64"
        case .linuxFEX: "route.id.linux-fex"
        }
    }

    static func name(_ route: RouteID) -> String {
        L10n.string(nameKey(route))
    }

    /// A session record's route: a `RouteID` raw value, the test route, or a route from a
    /// newer build, shown raw.
    static func name(recorded raw: String) -> String {
        if raw == SessionRecord.testRoute { return L10n.string("route.id.test") }
        return RouteID(rawValue: raw).map(name) ?? raw
    }

    static func verdictKey(_ verdict: RouteVerdict) -> LocalizedStringKey {
        switch verdict {
        case .runnable: "route.verdict.runnable"
        case .runnableWithWarnings: "route.verdict.runnableWithWarnings"
        case .planned: "route.verdict.planned"
        case .unavailable: "route.verdict.unavailable"
        }
    }

    /// One short sentence a non-expert can act on. `jitReason` explains `needsJIT`.
    static func reasonText(_ reason: RouteReason, jitReason: JITReasonCode?) -> String {
        switch reason {
        case .engineNotHandled(let engine):
            L10n.format("route.reason.engineNotHandled", EngineStrings.name(engine))
        case .needsWindowsBinary:
            L10n.string("route.reason.needsWindowsBinary")
        case .needsLinuxBinary:
            L10n.string("route.reason.needsLinuxBinary")
        case .architectureUnsupported(let architecture):
            L10n.format("route.reason.architectureUnsupported", EngineStrings.name(architecture))
        case .needsJIT:
            jitReason.map { L10n.format("route.reason.needsJIT", JITStrings.reasonSentence($0)) }
                ?? L10n.string("route.reason.needsJIT.noReason")
        case .box64Only32Bit:
            L10n.string("route.reason.box64Only32Bit")
        case .fexPreferredWithJIT:
            L10n.string("route.reason.fexPreferredWithJIT")
        case .gateFailed(let gate, let stale):
            stale ? L10n.string("route.reason.gateFailed.stale")
                : L10n.format("route.reason.gateFailed", GateStrings.name(gate))
        case .gateUnmeasured(let gate):
            L10n.format("route.reason.gateUnmeasured", GateStrings.name(gate))
        case .notInThisBuild:
            L10n.string("route.reason.notInThisBuild")
        case .runtimeDeclined(let code):
            declineText(code)
        case .nativeFirst:
            L10n.string("route.reason.nativeFirst")
        case .overriddenByUser:
            L10n.string("route.reason.overriddenByUser")
        }
    }

    /// `route.decline.<raw>` from the owning runtime split, else a generic sentence with
    /// the raw code: the one intentional fallback here, since decline codes are open.
    static func declineText(_ code: RuntimeDeclineCode) -> String {
        L10n.existing("route.decline.\(code.rawValue)") ?? L10n.format("route.decline.generic", code.rawValue)
    }
}

/// 01's JIT reason sentences, for text that embeds them.
enum JITStrings {
    static func reasonSentence(_ reason: JITReasonCode) -> String {
        switch reason {
        case .dopamineJITOff: L10n.string("jit.reason.dopamineJITOff")
        case .rootlessJailbreakNoJIT: L10n.string("jit.reason.rootlessJailbreakNoJIT")
        case .trollStoreRequestPending: L10n.string("jit.reason.trollStoreRequestPending")
        case .trollStoreTimedOut: L10n.string("jit.reason.trollStoreTimedOut")
        case .sideloadedNoJIT: L10n.string("jit.reason.sideloadedNoJIT")
        case .txmEnforced: L10n.string("jit.reason.txmEnforced")
        case .txmUndetermined: L10n.string("jit.reason.txmUndetermined")
        case .probeSkippedAfterCrash: L10n.string("jit.reason.probeSkippedAfterCrash")
        case .probeFailed: L10n.string("jit.reason.probeFailed")
        case .unknownInstallNoJIT: L10n.string("jit.reason.unknownInstallNoJIT")
        case .simulator: L10n.string("jit.reason.simulator")
        }
    }
}
