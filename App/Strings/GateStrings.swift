import EikonCore
import SwiftUI

enum GateStrings {
    /// Known gates by name; any other (from a later split) gets a generic sentence with
    /// its raw name. The one intentional non-exhaustive map, since gate names are open.
    static func name(_ gate: GateName) -> String {
        switch gate {
        case .x18: L10n.string("gate.name.x18")
        case .guestWindow: L10n.string("gate.name.guestWindow")
        default: L10n.format("gate.name.generic", gate.rawValue)
        }
    }

    static func stateKey(_ state: GateState) -> LocalizedStringKey {
        switch state {
        case .passed: "gate.state.passed"
        case .failed(stale: false): "gate.state.failed"
        case .failed(stale: true): "gate.state.failedStale"
        case .unmeasured: "gate.state.unmeasured"
        }
    }
}
